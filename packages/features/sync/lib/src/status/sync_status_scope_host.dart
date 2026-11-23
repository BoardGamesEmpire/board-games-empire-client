import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:interfaces/repositories.dart';
import 'package:sync_queue/src/status/session_sync_status.dart';
import 'package:sync_queue/src/status/sync_status_cubit.dart';
import 'package:ui/ui.dart';

/// Puts the session's [SessionSyncStatus] in a `BgeSyncStatusScope` over
/// [child], so the rows and lines below read it without a bloc of their own
/// (#47).
///
/// It owns one [SyncStatusCubit] per [queue]: a rebuild with the same queue
/// keeps it, a different queue gets a new one, and the old one is closed.
///
/// The scope holds each half of the status as it stands: a count not yet
/// read, or whose last read failed, is null there, so nothing below claims
/// that everything has synced from zeros nobody read. The other half stands
/// regardless, so a row whose change is stuck says so while the pending
/// count is still on its way, or failing.
///
/// The scope is built whether or not there is a queue, holding nothing
/// without one, so the tree keeps its shape, and [child] its state, when a
/// session's queue arrives or goes.
///
/// The scope also carries the same state as a relay
/// (`BgeSyncStatusScope.relay`), one listenable for the host's life, for a
/// pop-up on the root navigator, above this host, to put back over its
/// content (#960). It holds each status as it arrives, goes back to nothing
/// read when [queue] goes or changes, as that frame ends and before the new
/// queue's first status, never mid-build, and is disposed with the host.
/// Disposing doesn't clear it, as the tree is locked then, so a pop-up that
/// outlives its host keeps the last state; the app closes its pop-ups when
/// a session ends and when another replaces it in place.
class SyncStatusScopeHost extends StatefulWidget {
  const SyncStatusScopeHost({
    required this.queue,
    required this.child,
    this.onStatus,
    super.key,
  });

  /// The session's queue; null where there is none to read, and the scope
  /// holds nothing.
  final SyncQueueRepository? queue;

  final Widget child;

  /// Told the status, for a holder outside [child], such as the offline
  /// strip above the navigator (#47).
  ///
  /// `owner` is this host's `State`, the same object on every call, so a
  /// holder that more than one host reports to can tell whose status it
  /// holds.
  ///
  /// A status is reported only as it arrives from the queue's stream, never
  /// while the tree builds: not from `initState`, `build` or
  /// `didUpdateWidget`. A holder may notify its listeners at once, even ones
  /// above this host. Until the queue's first read, nothing is reported, and
  /// a holder with no report has nothing to count.
  ///
  /// Each status is reported as it stands, either half possibly unread. Its
  /// [SessionSyncStatus.waiting] is the pending count's last read, or null
  /// before that first read and once a read fails, so a holder that counts
  /// what is waiting never shows a count that is stale or made up.
  ///
  /// Null withdraws the status, and is reported at once by a host that had
  /// a queue: from `dispose`, and from `didUpdateWidget` when [queue] goes
  /// or changes, to the callback the old widget held. That can be mid-build,
  /// or while the tree is locked, so a holder defers anything it notifies
  /// for a null.
  final void Function(Object owner, SessionSyncStatus? status)? onStatus;

  @override
  State<SyncStatusScopeHost> createState() => _SyncStatusScopeHostState();
}

class _SyncStatusScopeHostState extends State<SyncStatusScopeHost> {
  SyncStatusCubit? _cubit;
  StreamSubscription<SessionSyncStatus>? _changes;
  final ValueNotifier<BgeSyncStatusData> _relay = ValueNotifier(
    const BgeSyncStatusData(),
  );

  // Whether the relay still holds a dropped queue's status, to clear once
  // the frame that dropped it has built.
  bool _clearRelay = false;

  @override
  void initState() {
    super.initState();
    _follow(widget.queue);
  }

  @override
  void didUpdateWidget(SyncStatusScopeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.queue, widget.queue)) return;
    final hadQueue = _cubit != null;
    _stop();
    // The old queue's numbers no longer hold, whether the queue went or
    // another session's replaced it. Withdrawn from the holder that was told
    // them, which may not be the one the new widget names, and before the
    // new queue is followed. The new one's arrive from its stream.
    if (hadQueue) oldWidget.onStatus?.call(this, null);
    _clearRelayAfterBuild();
    _follow(widget.queue);
  }

  void _follow(SyncQueueRepository? queue) {
    if (queue == null) return;
    final cubit = _cubit = SyncStatusCubit(queue: queue);
    // A stream event is never delivered during a build, which is what lets
    // a holder notify as it is told.
    _changes = cubit.stream.listen((status) {
      setState(() {});
      _clearRelay = false;
      _relay.value = BgeSyncStatusData(
        waiting: status.waiting,
        stuck: status.stuck,
        stuckRecordIds: status.stuckRecordIds,
      );
      widget.onStatus?.call(this, status);
    });
  }

  // Not at once: this runs mid-build, and the relay's listeners are pop-ups
  // outside this host, which can't be marked dirty then. At the end of the
  // frame instead, which comes before any stream event, so before the new
  // queue's first status; one that somehow came first stands.
  void _clearRelayAfterBuild() {
    if (_relay.value == const BgeSyncStatusData()) return;
    _clearRelay = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !_clearRelay) return;
        _clearRelay = false;
        _relay.value = const BgeSyncStatusData();
      }, debugLabel: 'SyncStatusScopeHost.clearRelay')
      // A rebuild outside a frame waits for the next one; ask for it.
      ..ensureVisualUpdate();
  }

  void _stop() {
    unawaited(_changes?.cancel());
    _changes = null;
    unawaited(_cubit?.close());
    _cubit = null;
  }

  @override
  void dispose() {
    // Only a host that had a queue can have told a holder anything.
    final hadQueue = _cubit != null;
    _stop();
    if (hadQueue) widget.onStatus?.call(this, null);
    _relay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Without a queue, the scope's defaults: nothing read, so no count and
    // no record, and never the last status of a cubit this host has dropped.
    final status = _cubit?.state;
    return BgeSyncStatusScope(
      waiting: status?.waiting,
      stuck: status?.stuck,
      stuckRecordIds: status?.stuckRecordIds ?? const {},
      relay: _relay,
      child: widget.child,
    );
  }
}
