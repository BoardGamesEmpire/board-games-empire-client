import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// The [SyncOperationSender] the inline household create and the queue drain
/// both deliver through (#121).
///
/// It dispatches on the op's type to the remote that sends it, and
/// acknowledges a success through the repository that owns the row, naming
/// the queue entry so the row and the entry settle in one transaction:
///
/// - a household create goes out keyed by its `localId` (#131) and is
///   acknowledged with [HouseholdRepository.reconcileCreatedHousehold];
/// - an event create goes out keyed by its `localId` too, and is
///   acknowledged with [EventRepository.reconcileCreatedEvent] (#499). A
///   replay of a create whose event was deleted since is acknowledged the
///   same way, and leaves no event;
/// - a collection add, update or remove is acknowledged with
///   [GameCollectionRepository.reconcileFromServer], which replays the ops
///   still queued behind it (#429). A removal the server reports as already
///   done is acknowledged with [GameCollectionRepository.confirmRemoved].
///
/// A failed request is judged by the exception's variant and status, as
/// [SyncFailure] sets out, and recorded on the entry: parked, counted, or
/// handed back. Every exception family carries the status, so none of this
/// waits on a shared classifier (#260).
///
/// Every queue write that records an outcome is bookkeeping. If one throws,
/// it is logged and the outcome is returned anyway: the entry stays claimed
/// until its lease runs out, and then any sender can take it.
class SyncOperationSenderImpl implements SyncOperationSender {
  SyncOperationSenderImpl({
    required this._queue,
    required this._households,
    required this._householdRemote,
    required this._collection,
    required this._collectionRemote,
    required this._events,
    required this._eventRemote,
    BgeLogger? logger,
  }) : _log = logger ?? BgeLogger('bge.sync.sender');

  final SyncQueueRepository _queue;
  final HouseholdRepository _households;
  final HouseholdRemoteDataSource _householdRemote;
  final GameCollectionRepository _collection;
  final GameCollectionRemoteDataSource _collectionRemote;
  final EventRepository _events;
  final EventRemoteDataSource _eventRemote;
  final BgeLogger _log;

  @override
  Future<SyncDelivery> deliver(String entryId, SyncOperation operation) async {
    if (!await _queue.claim(entryId)) return _notClaimed(entryId, operation);
    return _dispatch(entryId, operation);
  }

  @override
  Future<SyncDelivery> deliverEntry(SyncQueueEntry entry) async {
    // Each claim names the payload [entry] was read with, so an op rewritten
    // since, as an add's acknowledgement rewrites the ops behind it, is left
    // for a sender that reads it again.
    final SyncOperation operation;
    try {
      operation = entry.operation;
    } on Object catch (error) {
      if (!await _queue.claim(entry.id, payload: entry.payload)) {
        return const SyncNotClaimed();
      }
      _log.warn(
        'A queued payload could not be decoded; counted',
        error: error,
        context: {'entryId': entry.id},
      );
      return _record(entry.id, SyncFailed(SyncFailure.invalidOp, error));
    }
    if (!await _queue.claim(entry.id, payload: entry.payload)) {
      return _notClaimed(entry.id, operation);
    }
    return _dispatch(entry.id, operation);
  }

  SyncDelivery _notClaimed(String entryId, SyncOperation operation) {
    _log.debug(
      'Queued op is held by another sender, rewritten since it was read, or '
      'no longer claimable',
      context: _context(entryId, operation),
    );
    return const SyncNotClaimed();
  }

  /// Sends [operation], claimed under [entryId], and records the outcome.
  Future<SyncDelivery> _dispatch(
    String entryId,
    SyncOperation operation,
  ) async {
    final delivery = await switch (operation) {
      CreateHouseholdOperation() => _createHousehold(entryId, operation),
      CreateEventOperation() => _createEvent(entryId, operation),
      AddToCollectionOperation() => _addToCollection(entryId, operation),
      UpdateCollectionOperation() => _updateCollectionEntry(entryId, operation),
      RemoveFromCollectionOperation() => _removeFromCollection(
        entryId,
        operation,
      ),
    };
    _report(entryId, operation, delivery);
    return delivery;
  }

  // ── Dispatch ────────────────────────────────────────────────────────

  Future<SyncDelivery> _createHousehold(
    String entryId,
    CreateHouseholdOperation op,
  ) async {
    final Household created;
    try {
      created = await _householdRemote.createHousehold(
        name: op.name,
        // The same key on every attempt at this create, so a retry after a
        // lost response returns the household the first attempt made rather
        // than a second one (#131).
        clientRequestId: op.localId,
        description: op.description,
        image: op.image,
        language: op.language,
        visibility: op.visibility,
      );
    } on Object catch (error) {
      return _failedRequest(entryId, error);
    }
    return _acknowledge(entryId, () async {
      await _households.reconcileCreatedHousehold(
        created,
        localId: op.localId,
        completedSyncQueueId: entryId,
      );
      return SyncDelivered(householdId: created.id);
    });
  }

  Future<SyncDelivery> _createEvent(
    String entryId,
    CreateEventOperation op,
  ) async {
    final CreatedEvent created;
    try {
      created = await _eventRemote.createEvent(
        op.draft,
        // The same key on every attempt at this create, so a retry after a
        // lost response returns the event the first attempt made rather
        // than a second one (#499).
        clientRequestId: op.localId,
      );
    } on Object catch (error) {
      return _failedRequest(entryId, error);
    }
    // A replay of a create whose event was deleted since: the local event
    // goes, and nothing takes its place.
    final deleted = created.deletedAt != null;
    return _acknowledge(entryId, () async {
      await _events.reconcileCreatedEvent(
        created.snapshot,
        localId: op.localId,
        deleted: deleted,
        completedSyncQueueId: entryId,
      );
      return SyncDelivered(eventId: deleted ? null : created.snapshot.event.id);
    });
  }

  Future<SyncDelivery> _addToCollection(
    String entryId,
    AddToCollectionOperation op,
  ) async {
    final GameCollection added;
    try {
      added = await _collectionRemote.addToCollection(
        platformGameId: op.platformGameId,
        // Throws FormatException for a medium this build doesn't know: a
        // payload that won't map, judged as a client fault below.
        medium: GameMedium.fromWire(op.medium),
        quantity: op.quantity,
        rating: op.rating,
        comment: op.comment,
      );
    } on Object catch (error) {
      return _failedRequest(entryId, error);
    }
    return _reconcile(entryId, added);
  }

  Future<SyncDelivery> _updateCollectionEntry(
    String entryId,
    UpdateCollectionOperation op,
  ) async {
    final GameCollection updated;
    try {
      updated = await _collectionRemote.updateEntry(
        id: op.collectionId,
        quantity: op.quantity,
        rating: op.rating,
        comment: op.comment,
        favorite: op.favorite,
        playAgain: op.playAgain,
      );
    } on Object catch (error) {
      return _failedRequest(entryId, error);
    }
    // An entry the server has tombstoned answers 200 with `deletedAt` set,
    // and the reconcile purges it as a confirmed removal.
    return _reconcile(entryId, updated);
  }

  Future<SyncDelivery> _removeFromCollection(
    String entryId,
    RemoveFromCollectionOperation op,
  ) async {
    final GameCollection removed;
    try {
      removed = await _collectionRemote.removeEntry(op.collectionId);
    } on GameCollectionAlreadyRemovedException {
      // A re-sent removal the server had already applied: the work is done.
      // The answer carries no entry, so the tombstone is settled from the
      // local row; completing only the entry would leave it dirty for good.
      return _acknowledge(entryId, () async {
        await _collection.confirmRemoved(
          op.collectionId,
          completedSyncQueueId: entryId,
        );
        return const SyncDelivered();
      });
    } on Object catch (error) {
      return _failedRequest(entryId, error);
    }
    return _reconcile(entryId, removed);
  }

  // ── Recording the outcome ──────────────────────────────────────────

  /// Acknowledges a collection write the server accepted, completing the
  /// entry in the same transaction.
  Future<SyncDelivery> _reconcile(String entryId, GameCollection answer) =>
      _acknowledge(entryId, () async {
        await _collection.reconcileFromServer(
          answer,
          completedSyncQueueId: entryId,
        );
        return const SyncDelivered();
      });

  /// Runs [confirm], the local half of a send the server accepted.
  ///
  /// If it throws, the attempt is counted rather than handed back. A fault
  /// here may recur on every attempt, and an uncounted one would then be
  /// retried forever. The retry is safe: the server's half is replayed, not
  /// repeated, since a household or event create is keyed (#131, #499) and
  /// every collection write is an upsert, an absolute update or a removal.
  Future<SyncDelivery> _acknowledge(
    String entryId,
    Future<SyncDelivery> Function() confirm,
  ) async {
    try {
      return await confirm();
    } on Object catch (error) {
      return _record(entryId, SyncFailed(SyncFailure.localFault, error));
    }
  }

  Future<SyncDelivery> _failedRequest(String entryId, Object error) =>
      _record(entryId, _judge(error));

  /// What a failed request says about the op. See [SyncFailure].
  static SyncDelivery _judge(Object error) => switch (error) {
    // A success this device could not read, whichever variant carries it:
    // the server refused nothing, and most likely applied the write. Parked,
    // a household or event create would stay local-only beside the copy the
    // next hydrate brings. Counted, the retry replays it, as for a failed
    // acknowledgement (see [_acknowledge]).
    HouseholdRemoteException(statusCode: final status?) ||
    GameCollectionRemoteException(statusCode: final status?) ||
    EventRemoteException(statusCode: final status?)
        when status >= 200 && status < 300 =>
      SyncFailed(SyncFailure.localFault, error),
    HouseholdRemotePermanentException() ||
    GameCollectionRemotePermanentException() ||
    GameCollectionNotFoundException() ||
    // A create the API refused, such as for an invitee it won't take, is
    // refused the same way on every attempt (#499). The two read refusals
    // never come from a create, and would be refusals too if one did.
    EventCreateRefusedException() ||
    EventRemotePermanentException() ||
    EventRemoteForbiddenException() ||
    EventRemoteNotFoundException() => SyncParked(error),
    HouseholdRemoteTransientException(:final statusCode) ||
    GameCollectionRemoteTransientException(:final statusCode) ||
    EventRemoteTransientException(
      :final statusCode,
    ) => SyncFailed(_transientFailure(statusCode), error),
    // Raised before any request: a request the server would refuse, a
    // payload that won't map, a malformed id. The remotes wrap everything
    // they send, so neither reaches here from the network.
    ArgumentError() ||
    FormatException() => SyncFailed(SyncFailure.invalidOp, error),
    // Nothing else should escape a remote. Counted, so it is bounded.
    _ => SyncFailed(SyncFailure.localFault, error),
  };

  /// Which [SyncFailure] a transient answer carrying [status] is. Never a
  /// 2xx: [_judge] takes those first.
  ///
  /// The remotes call a 403, 404 or 407 transient only when nothing says the
  /// application wrote it, so those join the statuses that never reached
  /// it. A 409 is transient only when it says it is retryable (#431). Any
  /// other status is one the application answered, so it counts: bounding
  /// an answer this list doesn't know is safer than retrying it forever.
  static SyncFailure _transientFailure(int? status) => switch (status) {
    null => SyncFailure.unreachable,
    401 => SyncFailure.sessionRejected,
    403 || 404 || 407 || 408 || 429 => SyncFailure.unreachable,
    < 200 || (>= 300 && < 400) => SyncFailure.unreachable,
    _ => SyncFailure.serverError,
  };

  /// Records [delivery] on the entry, and returns it.
  Future<SyncDelivery> _record(String entryId, SyncDelivery delivery) async {
    switch (delivery) {
      case SyncParked(:final error):
        await _bookkeeping(
          entryId,
          'park',
          () => _queue.park(entryId, error: '$error'),
        );
      case SyncFailed(:final failure, :final error) when failure.counted:
        await _bookkeeping(
          entryId,
          'count the failed attempt at',
          () => _queue.markFailed(entryId, error: '$error'),
        );
      case SyncFailed():
        await _bookkeeping(entryId, 'hand back', () => _queue.release(entryId));
      case SyncDelivered() || SyncNotClaimed():
        break;
    }
    return delivery;
  }

  /// A queue write recording an outcome. If it throws, the entry stays
  /// claimed until its lease runs out, then any sender can take it.
  Future<void> _bookkeeping(
    String entryId,
    String what,
    Future<void> Function() write,
  ) async {
    try {
      await write();
    } on Object catch (error, stackTrace) {
      _log.error(
        'Could not $what the queued op; it is held until its lease runs out',
        error: error,
        stackTrace: stackTrace,
        context: {'entryId': entryId},
      );
    }
  }

  void _report(String entryId, SyncOperation op, SyncDelivery delivery) {
    final context = _context(entryId, op);
    switch (delivery) {
      case SyncDelivered():
        _log.debug('Delivered queued op', context: context);
      case SyncNotClaimed():
        break;
      case SyncParked(:final error):
        _log.warn(
          'The server refused a queued op; parked for a retry or discard by '
          'hand',
          error: error,
          context: context,
        );
      case SyncFailed(:final failure, :final error):
        _log.warn(
          'Queued op not delivered (${failure.name}); '
          '${failure.counted ? 'counted' : 'handed back'}',
          error: error,
          context: context,
        );
    }
  }

  static Map<String, dynamic> _context(String entryId, SyncOperation op) => {
    'entryId': entryId,
    'op': switch (op) {
      CreateHouseholdOperation() => CreateHouseholdOperation.type,
      CreateEventOperation() => CreateEventOperation.type,
      AddToCollectionOperation() => AddToCollectionOperation.type,
      UpdateCollectionOperation() => UpdateCollectionOperation.type,
      RemoveFromCollectionOperation() => RemoveFromCollectionOperation.type,
    },
  };
}
