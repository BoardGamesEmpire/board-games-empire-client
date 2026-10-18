import 'dart:async';

import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

/// Sends what the sync queue holds, through the one [SyncOperationSender]
/// the inline household create also uses (#121).
///
/// One pass reads every entry not yet completed, in queue order, and for
/// each checks the ordering rules and the cooldown below, then hands it to
/// the sender. The sender claims it, sends it and records the outcome; the
/// pass decides only whether to go on.
///
/// ## Where a pass stops
///
/// A failure that is about the op itself lets the pass go on: a refusal is
/// parked and a client fault counted, and neither says anything about the
/// next op. Any other failure stops it ([SyncFailure.stopsPass]): a server
/// that is down, throttling or refusing the session would fail every op the
/// same way, so a pass costs one request rather than one per queued op. A
/// refused session (401) also asks the auth layer whether the session still
/// stands, at most once per pass, so a revoked session signs the user out
/// through the existing path instead of leaving the drain stopped behind an
/// app that looks signed in.
///
/// ## One entry's ops stay in order
///
/// The queue entries for one collection entry go out in queue order. Within
/// a pass, once an op for an entry isn't delivered, for whatever reason, the
/// entry's later ops wait for a later pass. Across passes, an update or a
/// removal queued behind an add that isn't acknowledged yet is held while
/// its entry is local-only, parked adds included: the server has yet to
/// confirm the entry, and the add's acknowledgement is what gives it the id
/// the server knows it by, remapping the op onto it. The read a pass works
/// from includes exhausted entries for that reason, and which entries are
/// local-only. An add names the game rather than the id, so this rule holds
/// no add, though the order can: an add queued behind an op the rule holds
/// waits with it.
///
/// So while a parked add holds its entry's ops, a later add for the entry
/// waits with them, and nothing more goes out for the entry until the
/// parked add is retried or discarded by hand (#190). Sending the later add
/// first would not be safe: an update queued before it would then land
/// after it, and could undo what it set.
///
/// That acknowledgement rewrites the ops queued behind the add, so after a
/// delivered add that has any, the pass reads the queue again and sends them
/// as rewritten. Whatever rewrites an op, the sender claims it only while it
/// holds the payload this pass read ([SyncOperationSender.deliverEntry]), so
/// an op rewritten since is left for the next pass, never sent stale.
///
/// An op that has exhausted its retries, parked or not, holds back nothing
/// from the next pass on, unless it is an add for a local-only entry. That
/// covers an update, a removal, and an add for an entry the server has
/// confirmed, such as one raising its quantity or an older add that a newer
/// one's acknowledgement remapped. The ops queued behind it name the entry
/// by an id the server knows, and holding them would freeze the entry's
/// newer edits behind one that may never be sent again. The cost is on the
/// row. A newer op's acknowledgement writes the server's answer, which
/// lacks the exhausted edit, so that edit stops showing even in fields the
/// newer op didn't carry, though the row stays dirty
/// ([GameCollectionRepository.reconcileFromServer]). That is what the row
/// shows until the exhausted op is retried or discarded (#190).
///
/// ## Spacing out counted retries
///
/// A failed entry waits [cooldownAfter] its retry count before it is tried
/// again, measured from the attempt that failed it, on the device clock that
/// stamped it. Without the wait, the retry budget would measure triggers
/// rather than time: five app resumes during one outage would exhaust an op
/// that a later attempt would have delivered. An attempt handed back
/// uncounted starts no wait: it leaves the entry pending, and it was made
/// only once any earlier wait was over. An entry whose payload won't decode
/// waits the same way; the wait reads only its status, retry count and last
/// attempt.
///
/// ## Completed history
///
/// A delivered op's entry is kept as completed for [completedRetention],
/// then deleted by a pass (#190): the first one, and after that at most one
/// per [purgeInterval], so a session that stays signed in for weeks keeps
/// its history bounded too. It is kept that long because a late
/// acknowledgement of an op delivered twice finds its place by it. A stuck
/// entry is never deleted here: it stays until the user retries or discards
/// it.
///
/// ## When it runs
///
/// Nothing wakes it on an enqueue; the inline create sends its own op, and a
/// wake would race it. It runs when its installer starts it and whenever the
/// session's rehydrator asks, which consults [isStale] first.
class SyncQueueDrain {
  /// [collection] says which entries the server has yet to confirm, which
  /// the ordering rules need. [revalidateSession] asks the auth layer
  /// whether the session still stands after a refused send; null skips the
  /// question. [now] is the device clock, which stamps every attempt; a test
  /// drives it so a cooldown costs no real time.
  SyncQueueDrain({
    required this._queue,
    required this._sender,
    required this._collection,
    this._revalidateSession,
    DateTime Function()? now,
    BgeLogger? logger,
  }) : _now = now ?? _deviceNow,
       _log = logger ?? BgeLogger('bge.sync.drain') {
    _counts = _queue.watchPendingCount().listen(
      (count) => _seenCount = count,
      // The stream closes with its repository; an error only means no more
      // answers, and a pass will find out the same way.
      onError: (Object _) {},
    );
  }

  static DateTime _deviceNow() => DateTime.now().toUtc();

  /// How long an op waits after a counted failure, by its retry count.
  ///
  /// Recorded as a guess, like the hydrates' staleness windows. The first
  /// gap is short because a single blip should clear while the user is still
  /// looking; the later ones stretch so that the fifth counted failure, the
  /// one that exhausts the op, comes at least seven hours after the first. The
  /// feedback queue's fixed hour is the precedent: its five attempts span at
  /// least four hours. A proxy's 502 for a server that is down counts as a
  /// server error, so this curve is also how long an outage the retry budget
  /// survives.
  static Duration cooldownAfter(int retryCount) => switch (retryCount) {
    <= 0 => Duration.zero,
    1 => const Duration(minutes: 1),
    2 => const Duration(minutes: 10),
    3 => const Duration(hours: 1),
    _ => const Duration(hours: 6),
  };

  /// How long a completed entry is kept before a pass's purge deletes it.
  ///
  /// Far longer than any request outlives the claim lease, and so than any
  /// acknowledgement that still needs the entry.
  static const Duration completedRetention = Duration(hours: 24);

  /// The least time between two purges, so a busy session doesn't run one
  /// on every pass. A completed entry can outlive [completedRetention] by up
  /// to this much.
  static const Duration purgeInterval = Duration(hours: 1);

  final SyncQueueRepository _queue;
  final SyncOperationSender _sender;
  final GameCollectionRepository _collection;
  final Future<void> Function()? _revalidateSession;
  final DateTime Function() _now;
  final BgeLogger _log;

  late final StreamSubscription<int> _counts;

  /// The pass running now, or null.
  Future<void>? _inFlight;

  bool _closed = false;

  /// When a pass last purged completed history, on the device clock. Null
  /// until the first pass.
  DateTime? _purgedAt;

  /// The pending count the queue last reported.
  int? _seenCount;

  /// When the last pass settled, the pending count then, and when that
  /// pass's schedule says something can next be sent. Null until a pass
  /// settles.
  DateTime? _settledAt;
  int? _settledCount;
  DateTime? _nextSendableAt;

  /// Whether a pass would find anything to send now.
  ///
  /// Synchronous, because the rehydrator asks it on every trigger, so it
  /// answers from what the last pass left: whether the queue has changed
  /// since, and when its earliest cooldown or claim runs out. A trigger with
  /// nothing sendable, such as a visit to the household list while every op
  /// is cooling, therefore costs nothing. A clock set back since that pass
  /// makes it true: a failure stamped ahead of the clock waits no longer,
  /// which that pass's schedule could not foresee. A purge that is due
  /// makes it true too, so a session left signed in with nothing to send
  /// still keeps its history bounded. False while a pass is running, which
  /// drops a trigger rather than queueing it, as the hydrates do.
  bool get isStale {
    if (_closed || _inFlight != null) return false;
    final settledAt = _settledAt;
    if (settledAt == null || _seenCount != _settledCount) return true;
    final now = _now();
    if (now.isBefore(settledAt) || _purgeDue(now)) return true;
    final at = _nextSendableAt;
    return at != null && !now.isBefore(at);
  }

  /// Whether a pass at [now] would purge completed history.
  ///
  /// A clock set back past the last purge makes it due, or that purge would
  /// hold off the next until the clock caught up with it. What completed
  /// under the clock that ran ahead stays: its last attempt is still later
  /// than the cutoff.
  bool _purgeDue(DateTime now) {
    final purgedAt = _purgedAt;
    return purgedAt == null ||
        now.isBefore(purgedAt) ||
        !now.isBefore(purgedAt.add(purgeInterval));
  }

  /// Runs one pass. Never throws. A call while a pass is running joins it.
  Future<void> drain() {
    if (_closed) return Future<void>.value();
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final pass = _pass();
    _inFlight = pass;
    return pass.whenComplete(() {
      if (identical(_inFlight, pass)) _inFlight = null;
    });
  }

  /// Runs a pass that reads the queue after this call. Never throws.
  ///
  /// For a write the user is waiting on, such as a retried op (#190).
  /// [drain] joins a pass in flight, and that pass read the queue before the
  /// write, so this waits for it to finish and then runs or joins the next.
  /// That next pass started after the call either way.
  Future<void> drainAfterChange() async {
    final inFlight = _inFlight;
    if (inFlight != null) await inFlight;
    return drain();
  }

  /// Stops the drain. A pass in flight stops at its next op; nothing runs
  /// after this. Idempotent.
  ///
  /// It doesn't wait for that pass: the op in flight may be waiting on the
  /// network, and the scope teardown that calls this must not. That op's
  /// acknowledgement then meets disposed repositories and is retried after
  /// its claim runs out.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _counts.cancel();
  }

  Future<void> _pass() async {
    final tally = _Tally();
    final now = _now();
    if (_purgeDue(now)) {
      _purgedAt = now;
      await _purgeHistory();
    }
    try {
      await _send(tally);
    } on Object catch (error, stackTrace) {
      // A repository disposed with its session throws, but only once [close]
      // has run: a scope is disposed in reverse order of registration, and
      // the drain is registered after the repositories. Anything thrown while
      // the drain is open is a fault, a StateError included.
      if (!_closed) {
        _log.error(
          'Sync queue pass failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      tally.stoppedBy ??= _closed ? 'session ended' : 'queue unavailable';
    }
    await _settle();
    tally.report(_log);
  }

  Future<void> _send(_Tally tally) async {
    var snapshot = await _read();
    final visited = <String>{};
    final waiting = <String>{};
    var revalidated = false;

    for (var i = 0; i < snapshot.entries.length; i++) {
      final listed = snapshot.entries[i];
      if (!visited.add(listed.entry.id)) continue;
      if (_closed) {
        tally.stoppedBy = 'session ended';
        return;
      }

      final target = listed.target;
      void holdTarget() {
        if (target != null) waiting.add(target);
      }

      switch (_verdict(listed, waiting, _now())) {
        case _Spent():
          continue;
        case _Waiting():
          holdTarget();
          tally.waiting++;
          continue;
        case _Held():
          holdTarget();
          tally.held++;
          continue;
        case _Sendable():
          break;
      }

      final delivery = await _sender.deliverEntry(listed.entry);
      switch (delivery) {
        case SyncDelivered():
          tally.delivered++;
          if (listed.op is AddToCollectionOperation &&
              snapshot.isShared(listed)) {
            // Its acknowledgement remapped the entry's other ops onto the
            // server id, so the payloads read above are stale. Read again,
            // past what this pass has already visited, so they go out now.
            snapshot = await _read();
            i = -1;
          }
        case SyncNotClaimed():
          holdTarget();
        case SyncParked():
          holdTarget();
          tally.parked++;
        case SyncFailed(:final failure):
          holdTarget();
          tally.failed++;
          if (failure == SyncFailure.sessionRejected && !revalidated) {
            revalidated = true;
            await _revalidate();
          }
          if (failure.stopsPass) {
            tally.stoppedBy = failure.name;
            return;
          }
      }
    }
  }

  /// Deletes completed entries older than [completedRetention]. Its failure
  /// costs nothing but space, so it is logged and the pass goes on.
  Future<void> _purgeHistory() async {
    try {
      final purged = await _queue.purgeCompleted(olderThan: completedRetention);
      if (purged > 0) {
        _log.debug(
          'Purged completed sync queue history',
          context: {'purged': purged},
        );
      }
    } on Object catch (error, stackTrace) {
      if (!_closed) {
        _log.warn(
          'Could not purge completed sync queue history',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// Every entry not yet completed, as one read finds them, and which
  /// collection entries the server has yet to confirm.
  ///
  /// The queue is read first. Each add is queued in one transaction with the
  /// write to its entry, so the second read finds every listed add's entry
  /// at least as that write left it.
  Future<_Snapshot> _read() async {
    final outstanding = await _queue.getOutstandingEntries();
    return _Snapshot(
      outstanding,
      localOnly: await _collection.getLocalOnlyIds(),
    );
  }

  /// What the rules say about [listed] at [now], given the targets this walk
  /// already holds back in [waiting].
  ///
  /// A pass and [_nextSendable] both walk the queue by this, so what
  /// [isStale] expects a pass to send is what a pass would send.
  static _Verdict _verdict(_Listed listed, Set<String> waiting, DateTime now) {
    if (listed.entry.isExhausted) return const _Spent();
    if (waiting.contains(listed.target)) return const _Held();
    final readyAt = _readyAt(listed.entry, now);
    if (readyAt != null && readyAt.isAfter(now)) return _Waiting(readyAt);
    if (listed.behindAdd) return const _Held();
    return const _Sendable();
  }

  /// When [entry] may next be tried, or null for now.
  ///
  /// A failed entry waits out its cooldown from its last attempt, the one
  /// that failed it: a later attempt would have left it claimed, or pending
  /// once handed back. A claimed entry waits for the claim to run out, judged
  /// as [SyncQueueRepository.claim] judges it, so a stamp ahead of a clock
  /// that was set back waits until the clock passes it too. A pending entry
  /// is ready, whether it is fresh or was handed back uncounted.
  static DateTime? _readyAt(SyncQueueEntry entry, DateTime now) {
    final last = entry.lastAttemptAt;
    if (last == null) return null;
    return switch (entry.status) {
      // A failure stamped later than [now] means the clock moved back past
      // it, and how long the entry has really waited is unknowable, so it
      // waits no longer. The queue lists a failed entry whatever its stamp.
      SyncStatus.failed when last.isAfter(now) => null,
      SyncStatus.failed => last.add(cooldownAfter(entry.retryCount)),
      SyncStatus.inProgress => last.add(SyncQueueEntry.claimLease),
      SyncStatus.pending || SyncStatus.completed => null,
    };
  }

  Future<void> _revalidate() async {
    final revalidate = _revalidateSession;
    if (revalidate == null) return;
    try {
      await revalidate();
    } on Object catch (error, stackTrace) {
      // An indeterminate answer leaves the session as it was; the next
      // refused send asks again.
      _log.warn(
        'Could not revalidate the session after a refused send',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Records what [isStale] answers from until the next pass: the pending
  /// count now, and when the earliest op could next be sent.
  ///
  /// The read takes in entries another sender holds, as a pass's does: the
  /// inline create can be mid-send while this settles, and if its send
  /// fails without changing the count, its claim's expiry is the only thing
  /// left that would make the drain look again.
  ///
  /// The count comes from that same read, so the two describe one queue.
  /// Read apart, a write landing between them, such as that create's
  /// completion, would cache a count from before it with a schedule from
  /// after: once a new op brought the count back to the cached one,
  /// [isStale] would find nothing scheduled, and the op would wait for the
  /// count to move again.
  Future<void> _settle() async {
    if (_closed) return;
    try {
      final snapshot = await _read();
      final now = _now();
      _nextSendableAt = _nextSendable(snapshot, now);
      _settledCount = snapshot.pendingCount;
      _settledAt = now;
    } on Object catch (error, stackTrace) {
      // The schedule stays as it was: stale until a pass settles, so the
      // next trigger tries again.
      if (!_closed) {
        _log.error(
          'Could not schedule the next sync queue pass',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// The earliest time a pass could send something from [snapshot]: [now]
  /// when one is sendable already, the end of the earliest wait when every
  /// candidate is waiting, or null when nothing will be sendable until the
  /// queue changes.
  static DateTime? _nextSendable(_Snapshot snapshot, DateTime now) {
    final waiting = <String>{};
    DateTime? earliest;
    for (final listed in snapshot.entries) {
      final target = listed.target;
      switch (_verdict(listed, waiting, now)) {
        case _Spent():
          break;
        case _Sendable():
          return now;
        case _Waiting(:final until):
          if (earliest == null || until.isBefore(earliest)) earliest = until;
          if (target != null) waiting.add(target);
        case _Held():
          if (target != null) waiting.add(target);
      }
    }
    return earliest;
  }
}

/// The queue as one read found it: every entry not yet completed, in queue
/// order, each decoded once, with what the ordering rules need to know about
/// it.
class _Snapshot {
  factory _Snapshot(
    List<SyncQueueEntry> outstanding, {
    required Set<String> localOnly,
  }) {
    final entries = <_Listed>[];
    final sharing = <String, int>{};
    final added = <String>{};
    for (final entry in outstanding) {
      final op = _decode(entry);
      final target = op == null ? null : _targetOf(op);
      final namesEntryById = switch (op) {
        UpdateCollectionOperation() || RemoveFromCollectionOperation() => true,
        AddToCollectionOperation() ||
        CreateHouseholdOperation() ||
        null => false,
      };
      entries.add(
        _Listed(
          entry,
          op,
          target,
          behindAdd: namesEntryById && added.contains(target),
        ),
      );
      if (target != null) {
        sharing[target] = (sharing[target] ?? 0) + 1;
        if (op is AddToCollectionOperation && localOnly.contains(op.localId)) {
          added.add(target);
        }
      }
    }
    return _Snapshot._(entries, sharing);
  }

  _Snapshot._(this.entries, this._sharing);

  final List<_Listed> entries;

  /// The pending count as this read found it:
  /// [SyncQueueRepository.getPendingCount] counts every entry not yet
  /// completed except the exhausted ones.
  int get pendingCount =>
      entries.where((listed) => !listed.entry.isExhausted).length;

  /// How many entries in this read share each target.
  final Map<String, int> _sharing;

  /// Whether another entry in this read shares [listed]'s target.
  bool isShared(_Listed listed) => (_sharing[listed.target] ?? 0) > 1;

  /// Decodes [entry]'s op, or null for a payload that won't decode.
  static SyncOperation? _decode(SyncQueueEntry entry) {
    try {
      return entry.operation;
    } on Object {
      return null;
    }
  }

  /// The key one entry's ops share, so they go out in order.
  static String _targetOf(SyncOperation op) => switch (op) {
    AddToCollectionOperation(:final localId) => 'collection:$localId',
    UpdateCollectionOperation(:final collectionId) =>
      'collection:$collectionId',
    RemoveFromCollectionOperation(:final collectionId) =>
      'collection:$collectionId',
    CreateHouseholdOperation(:final localId) => 'household:$localId',
  };
}

/// One entry of a [_Snapshot].
class _Listed {
  const _Listed(this.entry, this.op, this.target, {required this.behindAdd});

  final SyncQueueEntry entry;

  /// Null for a payload that won't decode, which the sender counts. It names
  /// no entry, so it holds nothing back.
  final SyncOperation? op;

  /// The key its entry's ops share; null when [op] is.
  final String? target;

  /// An update or a removal queued behind an add for its entry that this
  /// read still holds, parked or not, while the entry is local-only: until
  /// the server confirms the entry, the add's acknowledgement can still
  /// change the id the op names.
  final bool behindAdd;
}

/// What the rules say about one entry of a [_Snapshot].
sealed class _Verdict {
  const _Verdict();
}

/// Exhausted: no pass sends it, and it holds nothing back.
final class _Spent extends _Verdict {
  const _Spent();
}

/// Ready to send.
final class _Sendable extends _Verdict {
  const _Sendable();
}

/// Cooling, or claimed by another sender, until [until].
final class _Waiting extends _Verdict {
  const _Waiting(this.until);

  final DateTime until;
}

/// Behind an op of its entry that goes first: it waits on that op, with no
/// time of its own.
final class _Held extends _Verdict {
  const _Held();
}

/// What one pass did, for its log line.
class _Tally {
  int delivered = 0;
  int parked = 0;
  int failed = 0;
  int waiting = 0;
  int held = 0;
  String? stoppedBy;

  bool get attempted => delivered + parked + failed > 0;

  void report(BgeLogger log) {
    final context = {
      'delivered': delivered,
      'parked': parked,
      'failed': failed,
      'waiting': waiting,
      'held': held,
      'stoppedBy': ?stoppedBy,
    };
    // The rehydrator only reports in debug builds, so a release build's
    // record of what the drain did is this line.
    if (attempted || stoppedBy != null) {
      log.info('Sync queue pass finished', context: context);
    } else {
      log.debug('Sync queue pass had nothing to send', context: context);
    }
  }
}
