import 'dart:async';

import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import 'stuck_sync_op.dart';

/// Lists the session's stuck ops, and retries or discards one by hand
/// (#190).
///
/// A stuck op is one the server refused or that ran out of retries. Nothing
/// sends or drops it on its own, so this is the only way out of the queue
/// for it.
///
/// - **Retry** puts the op back as new and sends it through the drain where
///   the session runs one. Where none does yet, which is web until #447, it
///   goes out inline through the sender. A collection op goes through
///   [SyncOperationSender.deliver], which leaves it queued while an earlier
///   op for its entry goes first, as the drain would.
/// - **Discard** deletes the op and undoes what it did locally, through the
///   repository that owns its rows, then refreshes that cache from the
///   server so the undone row shows the server's copy.
///
/// Built per screen from the session's container, so it never outlives the
/// repositories it reads.
class SyncRecovery {
  /// [drain] runs a pass that reads the queue after the call, and is
  /// preferred to an inline send through [sender] when given. The three
  /// refreshes each run a hydrate of their cache. Each is optional because a
  /// composition may not have it, and then that step is skipped.
  SyncRecovery({
    required this._queue,
    required this._collection,
    required this._households,
    required this._events,
    this._sender,
    this._drain,
    this._refreshCollection,
    this._refreshHouseholds,
    this._refreshEvents,
    BgeLogger? logger,
  }) : _log = logger ?? BgeLogger('bge.sync.recovery');

  final SyncQueueRepository _queue;
  final GameCollectionRepository _collection;
  final HouseholdRepository _households;
  final EventRepository _events;
  final SyncOperationSender? _sender;
  final Future<void> Function()? _drain;
  final Future<void> Function()? _refreshCollection;
  final Future<void> Function()? _refreshHouseholds;
  final Future<void> Function()? _refreshEvents;
  final BgeLogger _log;

  /// Every stuck op, in queue order, on subscribe and whenever the stuck set
  /// changes. Closes when the session's queue does.
  ///
  /// The queue emits on every write to it, a drain's claims and completions
  /// included, mostly with the same stuck set; only a changed one is
  /// described again, its titles read together.
  Stream<List<StuckSyncOp>> watch() => _queue
      .watchStuckEntries()
      .distinct(_sameEntries)
      .asyncMap((entries) => Future.wait(entries.map(_describe)));

  static bool _sameEntries(List<SyncQueueEntry> a, List<SyncQueueEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Puts [entryId] back in the queue and sends it, returning once the send
  /// is over. Returns false when the op is stuck again by then: the server
  /// refused it again, and it is parked once more.
  ///
  /// Sends nothing for an op that isn't stuck, such as one another tab
  /// already retried.
  Future<bool> retry(String entryId) async {
    if (!await _queue.retry(entryId)) return true;
    final drain = _drain;
    if (drain != null) {
      await drain();
    } else {
      final sender = _sender;
      final entry = await _queue.getEntry(entryId);
      if (sender == null || entry == null) return true;
      await _sendInline(sender, entry);
    }
    final after = await _queue.getEntry(entryId);
    return !(after?.isStuck ?? false);
  }

  /// Sends [entry] without a drain. One that won't decode is left reopened.
  ///
  /// A household or event create goes out as it is: no other op waits on
  /// it, which is why its create screen sends one inline too. A collection
  /// op goes through [SyncOperationSender.deliver], which holds it behind an
  /// earlier op for its entry. With no drain, nothing sends what an add's
  /// acknowledgement releases, or the op once what held it is done; those
  /// wait for a drain (#447).
  static Future<void> _sendInline(
    SyncOperationSender sender,
    SyncQueueEntry entry,
  ) async {
    final SyncOperation op;
    try {
      op = entry.operation;
    } on Object {
      return;
    }
    switch (op) {
      case CreateHouseholdOperation() || CreateEventOperation():
        await sender.deliverEntry(entry);
      case AddToCollectionOperation() ||
          UpdateCollectionOperation() ||
          RemoveFromCollectionOperation():
        await sender.deliver(entry.id, op);
    }
  }

  /// Deletes [entryId] and undoes what it did locally, then starts a
  /// refresh of the cache it touched, without waiting for it. A collection
  /// add or removal takes the later ops for its entry with it
  /// ([GameCollectionRepository.discardQueuedOp]).
  ///
  /// Does nothing for an op that isn't stuck: one still being worked on is
  /// not the user's to drop from here. The repositories check that in the
  /// statement that deletes it, so a retry from another tab can't slip in
  /// between. Throws, changing nothing, when the undo would delete a later
  /// op for the same entry that is being sent.
  Future<void> discard(String entryId) async {
    final entry = await _queue.getEntry(entryId);
    if (entry == null) return;
    final SyncOperation op;
    try {
      op = entry.operation;
    } on Object {
      // An event create a newer build queued still names its local event,
      // and the events repository deletes the two together.
      if (CreateEventOperation.localIdOf(entry.payload) != null) {
        if (await _events.discardQueuedOp(entryId)) {
          _refresh(_refreshEvents, 'events');
        }
      } else {
        await _queue.discardStuck(entryId);
      }
      return;
    }
    switch (op) {
      case CreateHouseholdOperation():
        if (await _households.discardQueuedOp(entryId)) {
          _refresh(_refreshHouseholds, 'households');
        }
      case CreateEventOperation():
        if (await _events.discardQueuedOp(entryId)) {
          _refresh(_refreshEvents, 'events');
        }
      case AddToCollectionOperation() ||
          UpdateCollectionOperation() ||
          RemoveFromCollectionOperation():
        if (await _collection.discardQueuedOp(entryId)) {
          _refresh(_refreshCollection, 'collection');
        }
    }
  }

  void _refresh(Future<void> Function()? refresh, String cache) {
    if (refresh == null) return;
    unawaited(
      refresh().catchError((Object error, StackTrace stackTrace) {
        // Refreshers report through their own status; this is a backstop.
        _log.warn(
          'Refresh after a discard failed',
          error: error,
          stackTrace: stackTrace,
          context: {'cache': cache},
        );
      }),
    );
  }

  Future<StuckSyncOp> _describe(SyncQueueEntry entry) async {
    final SyncOperation op;
    try {
      op = entry.operation;
    } on Object {
      return StuckSyncOp(entryId: entry.id, kind: StuckSyncOpKind.unreadable);
    }
    return switch (op) {
      CreateHouseholdOperation(:final name) => StuckSyncOp(
        entryId: entry.id,
        kind: StuckSyncOpKind.createHousehold,
        subject: name,
      ),
      CreateEventOperation(:final draft) => StuckSyncOp(
        entryId: entry.id,
        kind: StuckSyncOpKind.createEvent,
        subject: draft.title,
      ),
      AddToCollectionOperation(:final localId) => StuckSyncOp(
        entryId: entry.id,
        kind: StuckSyncOpKind.addToCollection,
        subject: await _titleOf(localId),
      ),
      UpdateCollectionOperation(:final collectionId) => StuckSyncOp(
        entryId: entry.id,
        kind: StuckSyncOpKind.updateCollection,
        subject: await _titleOf(collectionId),
      ),
      RemoveFromCollectionOperation(:final collectionId) => StuckSyncOp(
        entryId: entry.id,
        kind: StuckSyncOpKind.removeFromCollection,
        subject: await _titleOf(collectionId),
      ),
    };
  }

  /// The title, or null if it can't be read: the op is still listed, just
  /// without a name.
  Future<String?> _titleOf(String collectionId) async {
    try {
      return await _collection.titleOf(collectionId);
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Could not read the title for a stuck op',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}
