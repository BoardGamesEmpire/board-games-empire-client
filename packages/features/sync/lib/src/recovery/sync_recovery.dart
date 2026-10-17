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
///   the session runs one. Where none does yet, which is web until #447, a
///   household create goes out inline through the sender, and a collection
///   op waits for a drain: only a drain keeps one entry's ops in order.
/// - **Discard** deletes the op and undoes what it did locally, through the
///   repository that owns its rows, then refreshes that cache from the
///   server so the undone row shows the server's copy.
///
/// Built per screen from the session's container, so it never outlives the
/// repositories it reads.
class SyncRecovery {
  /// [drain] runs a pass that reads the queue after the call, and is
  /// preferred to an inline send through [sender] when given. The two
  /// refreshes run a hydrate of their cache. Each is optional because a
  /// composition may not have it, and then that step is skipped.
  SyncRecovery({
    required this._queue,
    required this._collection,
    required this._households,
    this._sender,
    this._drain,
    this._refreshCollection,
    this._refreshHouseholds,
    BgeLogger? logger,
  }) : _log = logger ?? BgeLogger('bge.sync.recovery');

  final SyncQueueRepository _queue;
  final GameCollectionRepository _collection;
  final HouseholdRepository _households;
  final SyncOperationSender? _sender;
  final Future<void> Function()? _drain;
  final Future<void> Function()? _refreshCollection;
  final Future<void> Function()? _refreshHouseholds;
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
      if (sender == null || entry == null || !_sendsInline(entry)) return true;
      await sender.deliverEntry(entry);
    }
    final after = await _queue.getEntry(entryId);
    return !(after?.isStuck ?? false);
  }

  /// Whether [entry] can go out without a drain. A household create can: no
  /// other op waits on it, as the inline create screen already sends it. A
  /// collection op can't, because only a drain holds it behind the add its
  /// entry is still waiting on, and sends what that add's acknowledgement
  /// releases.
  static bool _sendsInline(SyncQueueEntry entry) {
    try {
      return entry.operation is CreateHouseholdOperation;
    } on Object {
      return false;
    }
  }

  /// Deletes [entryId] and undoes what it did locally, then starts a
  /// refresh of the cache it touched, without waiting for it.
  ///
  /// Does nothing for an op that isn't stuck: one still being worked on is
  /// not the user's to drop from here. The repositories check that in the
  /// statement that deletes it, so a retry from another tab can't slip in
  /// between.
  Future<void> discard(String entryId) async {
    final entry = await _queue.getEntry(entryId);
    if (entry == null) return;
    final SyncOperation op;
    try {
      op = entry.operation;
    } on Object {
      await _queue.discardStuck(entryId);
      return;
    }
    switch (op) {
      case CreateHouseholdOperation():
        if (await _households.discardQueuedOp(entryId)) {
          _refresh(_refreshHouseholds, 'households');
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
