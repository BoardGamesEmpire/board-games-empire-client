import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:ui/ui.dart';

import '../support/streaming_queue.dart';

final SyncQueueEntry _stuckAdd = SyncQueueEntry(
  id: 'q1',
  payload: const AddToCollectionOperation(
    localId: 'local-1',
    platformGameId: 'p1',
    medium: 'physical',
    quantity: 1,
  ).serialized,
  createdAt: DateTime(2026),
);

/// One `onStatus` call: who reported, and what.
typedef _Report = ({Object owner, SessionSyncStatus? status});

/// The host that turns a session's queue into `BgeSyncStatusScope` (#47).
void main() {
  late StreamingQueue queue;

  setUp(() => queue = StreamingQueue());
  tearDown(() => unawaited(queue.dispose()));

  // What the probe under the host last read from the scope.
  ({int? waiting, int? stuck})? counts;
  bool? stuckLocal1;

  // Built once per test, so the host's own rebuilds pass the same child and
  // only the scope's notifications rebuild it.
  late Widget probe;

  setUp(() {
    counts = null;
    stuckLocal1 = null;
    probe = Builder(
      builder: (context) {
        counts = BgeSyncStatusScope.countsOf(context);
        stuckLocal1 = BgeSyncStatusScope.isStuckOf(context, 'local-1');
        return const SizedBox.shrink();
      },
    );
  });

  Widget host(
    SyncQueueRepository? queue, {
    void Function(Object owner, SessionSyncStatus? status)? onStatus,
  }) => SyncStatusScopeHost(queue: queue, onStatus: onStatus, child: probe);

  BgeSyncStatusScope scope(WidgetTester tester) =>
      tester.widget<BgeSyncStatusScope>(find.byType(BgeSyncStatusScope));

  // Neither count read.
  const unread = (waiting: null, stuck: null);

  // A queue event reaches the host's setState in the microtasks a pump
  // flushes after its frame, so the frame that shows it is the next one:
  // each event below is followed by pumpAndSettle, not a single pump.

  testWidgets("publishes each half of the cubit's status as it is read", (
    tester,
  ) async {
    await tester.pumpWidget(host(queue));
    // Nothing read yet: no counts, rather than zeros that would claim
    // everything had synced.
    expect(counts, unread);

    queue.pending.add(2);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 2, stuck: null));
    expect(stuckLocal1, isFalse);

    queue.stuck.add([_stuckAdd]);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 2, stuck: 1));
    expect(stuckLocal1, isTrue);
  });

  testWidgets('stuck records show before the pending count arrives', (
    tester,
  ) async {
    // As at a cold start where the stuck entries come back first: the row
    // says stuck from the start, never waiting first.
    await tester.pumpWidget(host(queue));
    queue.stuck.add([_stuckAdd]);
    await tester.pumpAndSettle();

    expect(counts, (waiting: null, stuck: 1));
    expect(stuckLocal1, isTrue);
  });

  testWidgets('a failed pending read unreads waiting alone, until it reads '
      'again', (tester) async {
    await tester.pumpWidget(host(queue));
    queue.pending.add(0);
    await tester.pumpAndSettle();
    queue.stuck.add([_stuckAdd]);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 0, stuck: 1));

    // The waiting count is no longer a read, so it goes; the stuck records
    // were read, and stay, so the row still says its change won't send.
    queue.pending.addError(StateError('read failed'));
    await tester.pumpAndSettle();
    expect(counts, (waiting: null, stuck: 1));
    expect(scope(tester).stuckRecordIds, {'local-1'});
    expect(stuckLocal1, isTrue);

    queue.pending.add(1);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 1, stuck: 1));
    expect(stuckLocal1, isTrue);
  });

  testWidgets('a failed stuck read unreads stuck and its records alone', (
    tester,
  ) async {
    await tester.pumpWidget(host(queue));
    queue.pending.add(2);
    await tester.pumpAndSettle();
    queue.stuck.add([_stuckAdd]);
    await tester.pumpAndSettle();

    queue.stuck.addError(StateError('read failed'));
    await tester.pumpAndSettle();
    expect(counts, (waiting: 2, stuck: null));
    expect(scope(tester).stuckRecordIds, isEmpty);
    expect(stuckLocal1, isFalse);
  });

  testWidgets('a null queue publishes a scope with nothing read', (
    tester,
  ) async {
    await tester.pumpWidget(host(null));

    // The scope is there all the same, so the tree keeps its shape when a
    // session's queue arrives.
    expect(scope(tester), isNotNull);
    expect(counts, unread);

    await tester.pumpWidget(host(queue));
    expect(counts, unread);
    queue.pending.add(0);
    queue.stuck.add(const []);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 0, stuck: 0));
  });

  testWidgets('a new queue gets a new subscription', (tester) async {
    final next = StreamingQueue();
    addTearDown(() => unawaited(next.dispose()));

    await tester.pumpWidget(host(queue));
    queue.pending.add(1);
    queue.stuck.add(const []);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 1, stuck: 0));

    await tester.pumpWidget(host(next));
    // The old queue's cubit is closed, which ends both its subscriptions at
    // once, and the new one starts from nothing read: the old counts go,
    // and the scope holds none until the new queue is read.
    expect(queue.pending.hasListener, isFalse);
    expect(queue.stuck.hasListener, isFalse);
    expect(next.pending.hasListener, isTrue);
    expect(next.stuck.hasListener, isTrue);
    expect(counts, unread);

    next.pending.add(4);
    next.stuck.add(const []);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 4, stuck: 0));

    // Nothing the old queue says reaches the scope any more.
    queue.pending.add(9);
    queue.stuck.add([_stuckAdd]);
    await tester.pumpAndSettle();
    expect(counts, (waiting: 4, stuck: 0));
    expect(stuckLocal1, isFalse);

    // The same host rebuilt with the same queue keeps its subscription.
    await tester.pumpWidget(host(next));
    expect(next.pending.hasListener, isTrue);
    expect(counts, (waiting: 4, stuck: 0));
  });

  testWidgets('reports each status, and null on dispose', (tester) async {
    final reports = <_Report>[];
    void record(Object owner, SessionSyncStatus? status) =>
        reports.add((owner: owner, status: status));

    await tester.pumpWidget(host(queue, onStatus: record));
    // Nothing is reported while the tree builds (#47): a holder above the
    // host notifies as it is told, and would mark an ancestor dirty
    // mid-build.
    expect(reports, isEmpty);

    queue.pending.add(2);
    await tester.pumpAndSettle();
    queue.stuck.add(const []);
    await tester.pumpAndSettle();
    // An equal state is not news.
    queue.pending.add(2);
    await tester.pumpAndSettle();
    queue.stuck.add([_stuckAdd]);
    await tester.pumpAndSettle();

    expect(reports.map((r) => r.status), [
      const SessionSyncStatus(waiting: 2),
      const SessionSyncStatus(waiting: 2, stuck: 0),
      const SessionSyncStatus(
        waiting: 2,
        stuck: 1,
        stuckRecordIds: {'local-1'},
      ),
    ]);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(reports.last.status, isNull);
    // One owner throughout, and it is the host's State: what a holder
    // compares to tell this host's reports from another's.
    expect(reports.map((r) => r.owner).toSet(), hasLength(1));
    expect(reports.first.owner, isA<State<SyncStatusScopeHost>>());
  });

  testWidgets('reports a status with a half unread as it is', (tester) async {
    // A holder counting what is waiting can take each one: the count is the
    // pending count's last read, or null once that read fails, so it is
    // never stale. Withholding it until the stuck entries are read would
    // drop a true count.
    final reports = <SessionSyncStatus?>[];

    await tester.pumpWidget(host(queue, onStatus: (_, s) => reports.add(s)));
    queue.pending.add(2);
    await tester.pumpAndSettle();
    queue.pending.addError(StateError('read failed'));
    await tester.pumpAndSettle();

    expect(reports, [
      const SessionSyncStatus(waiting: 2),
      const SessionSyncStatus(),
    ]);
  });

  testWidgets('a queue that goes or changes withdraws its status', (
    tester,
  ) async {
    final reports = <_Report>[];
    void record(Object owner, SessionSyncStatus? status) =>
        reports.add((owner: owner, status: status));
    final next = StreamingQueue();
    addTearDown(() => unawaited(next.dispose()));

    await tester.pumpWidget(host(queue, onStatus: record));
    queue.pending.add(2);
    await tester.pumpAndSettle();

    // Another session's queue: the old count no longer holds, and the new
    // one's arrives from its stream.
    await tester.pumpWidget(host(next, onStatus: record));
    expect(reports.map((r) => r.status), [
      const SessionSyncStatus(waiting: 2),
      null,
    ]);

    next.pending.add(3);
    await tester.pumpAndSettle();
    expect(reports.last.status, const SessionSyncStatus(waiting: 3));
    next.stuck.add([_stuckAdd]);
    await tester.pumpAndSettle();
    expect(stuckLocal1, isTrue);

    // No queue at all: the scope reads nothing and names no record, rather
    // than the last status of the cubit the host dropped.
    await tester.pumpWidget(host(null, onStatus: record));
    expect(reports.last.status, isNull);
    expect(counts, unread);
    expect(stuckLocal1, isFalse);
    expect(scope(tester).stuckRecordIds, isEmpty);
    expect(next.pending.hasListener, isFalse);
  });

  testWidgets('the withdrawal goes to the holder that was told, before the '
      'new queue is followed', (tester) async {
    final next = StreamingQueue();
    addTearDown(() => unawaited(next.dispose()));
    final toOld = <SessionSyncStatus?>[];
    final toNew = <SessionSyncStatus?>[];
    bool? nextFollowedAtWithdrawal;
    void old(Object owner, SessionSyncStatus? status) {
      toOld.add(status);
      if (status == null) nextFollowedAtWithdrawal = next.pending.hasListener;
    }

    await tester.pumpWidget(host(queue, onStatus: old));
    queue.pending.add(2);
    await tester.pumpAndSettle();

    // A new queue and a new holder in one rebuild.
    await tester.pumpWidget(host(next, onStatus: (_, s) => toNew.add(s)));

    expect(toOld, [const SessionSyncStatus(waiting: 2), null]);
    expect(toNew, isEmpty);
    // Withdrawn before the new queue's cubit subscribed.
    expect(nextFollowedAtWithdrawal, isFalse);
    expect(next.pending.hasListener, isTrue);
  });

  testWidgets('a host that never had a queue reports nothing', (tester) async {
    final reports = <SessionSyncStatus?>[];

    await tester.pumpWidget(host(null, onStatus: (_, s) => reports.add(s)));
    await tester.pumpWidget(const SizedBox.shrink());

    expect(reports, isEmpty);
  });

  testWidgets('reports a status only outside a build', (tester) async {
    // #47: the holder notifies as it is told, from above the host. A
    // status told while the tree builds or lays out would mark an ancestor
    // dirty mid-frame.
    final phases = <SchedulerPhase>[];
    void record(Object owner, SessionSyncStatus? status) {
      if (status != null) phases.add(SchedulerBinding.instance.schedulerPhase);
    }

    await tester.pumpWidget(host(queue, onStatus: record));
    queue.pending.add(2);
    await tester.pumpAndSettle();
    // An event that lands with a rebuild of the host pending.
    queue.stuck.add([_stuckAdd]);
    await tester.pumpWidget(host(queue, onStatus: record));
    await tester.pumpAndSettle();
    queue.pending.add(5);
    await tester.pumpAndSettle();

    expect(phases, hasLength(3));
    expect(phases, everyElement(isNot(SchedulerPhase.persistentCallbacks)));
  });

  testWidgets('the child keeps its State as a queue arrives and goes', (
    tester,
  ) async {
    // One tree shape with and without a queue (STYLE_GUIDE §4), so what
    // the host wraps, the whole navigation shell, keeps its state.
    Widget hosting(SyncQueueRepository? queue) =>
        SyncStatusScopeHost(queue: queue, child: const _Keeper());

    await tester.pumpWidget(hosting(null));
    final kept = tester.state(find.byType(_Keeper));

    await tester.pumpWidget(hosting(queue));
    expect(tester.state(find.byType(_Keeper)), same(kept));

    await tester.pumpWidget(hosting(null));
    expect(tester.state(find.byType(_Keeper)), same(kept));
  });
}

/// A child whose `State` a test can compare across the host's rebuilds.
class _Keeper extends StatefulWidget {
  const _Keeper();

  @override
  State<_Keeper> createState() => _KeeperState();
}

class _KeeperState extends State<_Keeper> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
