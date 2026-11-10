import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/src/entry/collection_entry_event.dart';
import 'package:game_collection/src/entry/collection_entry_state.dart';
import 'package:game_collection/src/sync/collection_sync.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

/// Drives one collection entry's detail, edit and removal (#46).
///
/// ## What it watches
///
/// [GameCollectionRepository.watchCollectionListItem] for [entryId]. A row
/// is `ready`; a null is `gone` (removed elsewhere, or never there) and keeps
/// the last item. A failed watch is `error`, logged, and keeps the last item;
/// the next row makes the view `ready` again, as does a row after `gone`,
/// since the entry came back. A watch that closes while the view is still
/// `loading` (the session ended) is `error`; one that closes later changes
/// nothing.
///
/// A [CollectionEntryRetried] in `error` lets that watch go and watches
/// again, `loading` until the new watch answers. A retry in any other view
/// does nothing, as does one that reaches the bloc while it closes.
///
/// ## Before the cache has it
///
/// An entry that isn't in the cache yet is not one that was removed. The
/// hydrate runs unawaited from session activation, so a link straight to an
/// entry, or a web reload over a cache that starts empty, can read the entry
/// before the hydrate writes it. So a null before any row was read stays
/// `loading` while the hydration status says the cache could still gain
/// it, as the household detail's absence does: a pass is running, or the
/// status hasn't spoken yet. It is `gone` once the status settles, or at
/// once when a pass has landed rows before, since that pass would have
/// brought it. No status (a composition with no collection hydrate) is
/// settled. A null after a row was read is `gone` at once: the cache was
/// warm, so it is a removal.
///
/// The bloc's own removal is the exception: once it has begun (`removing`,
/// `removed`), the null that removal causes changes nothing, so the screen
/// pops on `removed` instead of flashing `gone`. A failed removal
/// wrote nothing, so a null after it is `gone` as any other.
///
/// ## What an edit sends
///
/// The edit event carries the form's whole state and the entry the sheet
/// opened on, its `base`. The bloc sends only what differs from that base,
/// not from the row on screen now, which may have changed while the sheet
/// was open:
///
/// - `quantity`, if it differs.
/// - `rating`, if set and different. A null rating is unchanged (#679).
/// - `comment`, trimmed, if not blank and different. A blank one is
///   unchanged.
/// - `favorite` and `playAgain`, if they differ with null read as false.
///
/// So a field nobody touched is never sent, and never writes the value the
/// sheet opened with back over one changed elsewhere since. An edit that
/// changes nothing makes no call and ends `saved` with `changed: false`. An
/// edit needs no row of the bloc's own: its base is what it is judged by.
///
/// ## How it sends
///
/// [GameCollectionRepository.updateCollectionEntry] and
/// [GameCollectionRepository.removeFromCollection] write and queue in one
/// transaction, and the bloc sends the queued op at once
/// ([SendQueuedOpNow.sendNow]), as every write that queues one does. Whatever
/// the send's outcome ([CollectionEntryState.sync]), the change is in the
/// entry. A removal of an entry already removed queues nothing and ends
/// `removed` with no sync.
///
/// An edit or a removal submitted while either is under way, or after the
/// removal, is ignored.
///
/// ## What it never throws
///
/// A write that throws (the session ended, or the entry was removed
/// elsewhere) is logged and ends `saveFailed` or `removeFailed`; nothing is
/// thrown out of the bloc. A removal that throws once the watch has answered
/// null, before the removal (`gone`) or while it was under way, ends
/// `removed` instead, with no sync: the entry is not in the collection, which
/// is what was asked.
class CollectionEntryBloc
    extends Bloc<CollectionEntryEvent, CollectionEntryState> {
  CollectionEntryBloc({
    required this._repository,
    required this._sender,
    required this.entryId,
    Stream<Hydration>? hydration,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.collection.entry'),
       super(const CollectionEntryState()) {
    on<CollectionEntryRowChanged>(_onRowChanged);
    on<CollectionEntryWatchFailed>(_onWatchFailed);
    on<CollectionEntryWatchEnded>(_onWatchEnded);
    on<CollectionEntryEditSubmitted>(_onEditSubmitted);
    on<CollectionEntryRemoveConfirmed>(_onRemoveConfirmed);
    on<CollectionEntryActionCleared>(_onActionCleared);
    on<CollectionEntryRetried>(_onRetried);
    on<CollectionEntryHydrationUpdated>(_onHydrationUpdated);
    on<CollectionEntryHydrationEnded>(_onHydrationEnded);

    _watch = _watchEntry();
    _hasHydrationSource = hydration != null;
    _hydrationUpdates = hydration?.listen(
      (reading) => add(CollectionEntryHydrationUpdated(reading)),
      onError: (Object error, StackTrace stackTrace) => _logger.warn(
        'The collection hydration status stream failed',
        error: error,
        stackTrace: stackTrace,
      ),
      onDone: () => add(const CollectionEntryHydrationEnded()),
    );
  }

  /// The entry the screen shows.
  final String entryId;

  final GameCollectionRepository _repository;
  final SyncOperationSender _sender;
  final BgeLogger _logger;

  /// The current watch: the constructor's, or the last retry's.
  late StreamSubscription<GameCollectionListItem?> _watch;

  StreamSubscription<Hydration>? _hydrationUpdates;

  /// Set as [close] begins, so a retry that reaches the bloc while it closes
  /// opens no watch that [close] has already gone past.
  bool _closing = false;

  /// Whether any watch has answered with a row. See "Before the cache has
  /// it".
  bool _everRead = false;

  /// Whether the current watch's last answer was null.
  bool _absent = false;

  /// What the hydrate last said, and whether there is a status to say it,
  /// whether it has spoken, and whether its stream has closed. The default
  /// reading is also what no status means: idle, nothing landed.
  Hydration _hydration = const Hydration();
  bool _hasHydrationSource = false;
  bool _hydrationSeen = false;
  bool _hydrationDone = false;

  StreamSubscription<GameCollectionListItem?> _watchEntry() => _repository
      .watchCollectionListItem(entryId)
      .listen(
        (item) => add(CollectionEntryRowChanged(item)),
        onError: (Object error, StackTrace stackTrace) {
          _logger.warn(
            'Watching the collection entry failed',
            error: error,
            stackTrace: stackTrace,
          );
          add(const CollectionEntryWatchFailed());
        },
        onDone: () => add(const CollectionEntryWatchEnded()),
      );

  bool get _removalBegun =>
      state.action == CollectionEntryAction.removing ||
      state.action == CollectionEntryAction.removed;

  bool get _busy =>
      state.action == CollectionEntryAction.saving || _removalBegun;

  /// Whether an entry never read could still arrive with the hydrate: no pass
  /// has landed rows, and one is running or the status hasn't spoken. A
  /// status stream that closed can't say more, so it settles both.
  bool get _mayStillArrive {
    if (_everRead || _hydration.everRefreshed || _hydrationDone) return false;
    return _hydration.state == HydrationState.running ||
        (_hasHydrationSource && !_hydrationSeen);
  }

  void _onRowChanged(
    CollectionEntryRowChanged event,
    Emitter<CollectionEntryState> emit,
  ) {
    final item = event.item;
    _absent = item == null;
    if (item != null) {
      _everRead = true;
      return emit(state.withView(CollectionEntryView.ready, item: item));
    }
    // The bloc's own removal makes the entry vanish; that is not "gone", and
    // changes nothing the screen shows.
    if (_removalBegun) return;
    // Not in the cache yet is not removed: loading until the hydrate settles.
    if (_mayStillArrive) return;
    emit(state.withView(CollectionEntryView.gone));
  }

  void _onHydrationUpdated(
    CollectionEntryHydrationUpdated event,
    Emitter<CollectionEntryState> emit,
  ) {
    _hydrationSeen = true;
    _hydration = event.hydration;
    _settleAbsence(emit);
  }

  void _onHydrationEnded(
    CollectionEntryHydrationEnded event,
    Emitter<CollectionEntryState> emit,
  ) {
    _hydrationDone = true;
    _settleAbsence(emit);
  }

  /// An entry the watch answered null for while the hydrate could still bring
  /// it is `gone` once it can't.
  void _settleAbsence(Emitter<CollectionEntryState> emit) {
    if (state.view != CollectionEntryView.loading || !_absent) return;
    if (_mayStillArrive) return;
    emit(state.withView(CollectionEntryView.gone));
  }

  void _onWatchEnded(
    CollectionEntryWatchEnded event,
    Emitter<CollectionEntryState> emit,
  ) {
    // After a row the detail keeps showing it; its writes fail visibly. A
    // watch closed while loading (a disposed session's repository), before
    // any answer or while a null waited on the hydrate, never will answer.
    if (state.view != CollectionEntryView.loading) return;
    _logger.warn('The collection entry watch closed before answering');
    emit(state.withView(CollectionEntryView.error));
  }

  void _onWatchFailed(
    CollectionEntryWatchFailed event,
    Emitter<CollectionEntryState> emit,
  ) => emit(state.withView(CollectionEntryView.error));

  Future<void> _onRetried(
    CollectionEntryRetried event,
    Emitter<CollectionEntryState> emit,
  ) async {
    if (_closing || state.view != CollectionEntryView.error) return;
    // Loading before anything is awaited, so a second retry in the same turn
    // finds the view no longer `error` and opens no second watch.
    emit(state.withView(CollectionEntryView.loading));
    _absent = false;
    final failed = _watch;
    _watch = _watchEntry();
    await failed.cancel();
  }

  Future<void> _onEditSubmitted(
    CollectionEntryEditSubmitted event,
    Emitter<CollectionEntryState> emit,
  ) async {
    if (_busy) return;

    final base = event.base;
    final quantity = event.quantity != base.quantity ? event.quantity : null;
    final rating = event.rating != null && event.rating != base.rating
        ? event.rating
        : null;
    final trimmed = event.comment?.trim();
    // Against the base trimmed too: a comment another client saved with a
    // trailing space is untouched when the form still holds it.
    final comment =
        trimmed != null && trimmed.isNotEmpty && trimmed != base.comment?.trim()
        ? trimmed
        : null;
    final favorite = event.favorite != (base.favorite ?? false)
        ? event.favorite
        : null;
    final playAgain = event.playAgain != (base.playAgain ?? false)
        ? event.playAgain
        : null;

    if (quantity == null &&
        rating == null &&
        comment == null &&
        favorite == null &&
        playAgain == null) {
      return emit(
        state.withAction(CollectionEntryAction.saved, changed: false),
      );
    }

    emit(state.withAction(CollectionEntryAction.saving));

    final ({
      GameCollection entry,
      String syncQueueId,
      UpdateCollectionOperation operation,
    })
    updated;
    try {
      updated = await _repository.updateCollectionEntry(
        id: entryId,
        quantity: quantity,
        rating: rating,
        playAgain: playAgain,
        favorite: favorite,
        comment: comment,
      );
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Updating the collection entry failed',
        error: error,
        stackTrace: stackTrace,
      );
      return emit(state.withAction(CollectionEntryAction.saveFailed));
    }

    final delivery = await _send(
      updated.syncQueueId,
      updated.operation,
      'edit',
    );
    emit(
      state.withAction(
        CollectionEntryAction.saved,
        sync: CollectionSync.of(delivery),
      ),
    );
  }

  Future<void> _onRemoveConfirmed(
    CollectionEntryRemoveConfirmed event,
    Emitter<CollectionEntryState> emit,
  ) async {
    if (_busy) return;
    emit(state.withAction(CollectionEntryAction.removing));

    final ({String syncQueueId, RemoveFromCollectionOperation operation})?
    removed;
    try {
      removed = await _repository.removeFromCollection(entryId);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Removing the collection entry failed',
        error: error,
        stackTrace: stackTrace,
      );
      // Removed elsewhere and purged, while the confirm was up (`gone`) or
      // while this removal waited (its null ignored, as `removing`): it is
      // not in the collection, which is what was asked.
      if (_absent) {
        return emit(state.withAction(CollectionEntryAction.removed));
      }
      return emit(state.withAction(CollectionEntryAction.removeFailed));
    }

    // Already removed: nothing was queued, so nothing is sent.
    if (removed == null) {
      return emit(state.withAction(CollectionEntryAction.removed));
    }

    final delivery = await _send(
      removed.syncQueueId,
      removed.operation,
      'removal',
    );
    emit(
      state.withAction(
        CollectionEntryAction.removed,
        sync: CollectionSync.of(delivery),
      ),
    );
  }

  void _onActionCleared(
    CollectionEntryActionCleared event,
    Emitter<CollectionEntryState> emit,
  ) {
    switch (state.action) {
      case CollectionEntryAction.saved ||
          CollectionEntryAction.saveFailed ||
          CollectionEntryAction.removeFailed:
        emit(state.withAction(CollectionEntryAction.idle));
      case CollectionEntryAction.removed:
        // The screen couldn't close on it. Gone once the row is: the null the
        // removal caused was ignored while it was under way.
        emit(
          state
              .withView(_absent ? CollectionEntryView.gone : state.view)
              .withAction(CollectionEntryAction.idle),
        );
      case CollectionEntryAction.idle ||
          CollectionEntryAction.saving ||
          CollectionEntryAction.removing:
        break;
    }
  }

  Future<SyncDelivery> _send(
    String queueId,
    SyncOperation operation,
    String what,
  ) => _sender.sendNow(
    queueId,
    operation,
    onClaimFailed: (error, stackTrace) => _logger.error(
      'Could not claim the queued $what; left queued',
      error: error,
      stackTrace: stackTrace,
    ),
  );

  @override
  Future<void> close() async {
    _closing = true;
    await _hydrationUpdates?.cancel();
    await _watch.cancel();
    return super.close();
  }
}
