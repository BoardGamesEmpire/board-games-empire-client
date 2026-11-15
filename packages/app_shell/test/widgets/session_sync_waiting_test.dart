import 'dart:async';

import 'package:app_shell/src/widgets/session_sync_waiting.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:sync_queue/sync_queue.dart'
    show SessionSyncStatus, SyncStatusScopeHost;

/// A session's queue with [waiting] changes outstanding and none stuck,
/// whose watches stay open, as Drift's do.
class _Queue implements SyncQueueRepository {
  _Queue(this.waiting);

  final int waiting;

  @override
  Stream<int> watchPendingCount() =>
      Stream.multi((stream) => stream.add(waiting));

  @override
  Stream<List<SyncQueueEntry>> watchStuckEntries() =>
      Stream.multi((stream) => stream.add(const []));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Releases [owner]'s count from its `dispose`, which runs while the tree
/// is locked, as a session's host does when the session ends.
class _ReleasesOnDispose extends StatefulWidget {
  const _ReleasesOnDispose({required this.waiting, required this.owner});

  final SessionSyncWaiting waiting;
  final Object owner;

  @override
  State<_ReleasesOnDispose> createState() => _ReleasesOnDisposeState();
}

class _ReleasesOnDisposeState extends State<_ReleasesOnDispose> {
  @override
  void dispose() {
    widget.waiting.release(widget.owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Runs the microtasks queued so far, a release's deferred notify among
/// them.
Future<void> _flush() => Future<void>.microtask(() {});

/// The session's count of waiting changes, carried up to the offline strip
/// above the navigator (#47). A session that ends, or is replaced, must not
/// clear the count of the one that replaced it, nor notify while the tree
/// is locked.
void main() {
  late SessionSyncWaiting waiting;
  late int notified;

  setUp(() {
    notified = 0;
    waiting = SessionSyncWaiting()..addListener(() => notified++);
  });
  tearDown(() => waiting.dispose());

  test('starts with no count', () {
    expect(waiting.value, isNull);
  });

  test('report then release by the same owner clears', () async {
    final owner = Object();

    waiting.report(owner, 3);
    expect(waiting.value, 3);
    expect(notified, 1, reason: 'a report notifies at once');

    waiting.release(owner);
    expect(waiting.value, isNull, reason: 'cleared at once');
    expect(notified, 1, reason: 'its notify waits for a microtask');

    await _flush();
    expect(waiting.value, isNull);
    expect(notified, 2);
  });

  test(
    'release by an old owner after a new report keeps the new value',
    () async {
      final old = Object();
      final next = Object();
      waiting
        ..report(old, 2)
        ..report(next, 5);
      notified = 0;

      waiting.release(old);
      await _flush();

      expect(waiting.value, 5);
      expect(notified, 0);

      // The new owner still holds it.
      waiting.release(next);
      await _flush();
      expect(waiting.value, isNull);
      expect(notified, 1);
    },
  );

  test('a report before the release notifies wins', () async {
    final old = Object();
    final next = Object();
    waiting.report(old, 2);
    notified = 0;

    waiting
      ..release(old)
      ..report(next, 5);
    await _flush();

    expect(waiting.value, 5);
    expect(notified, 1, reason: "the report's own; the release's is dropped");
  });

  test('a repeated count notifies once', () {
    final owner = Object();

    waiting
      ..report(owner, 2)
      ..report(owner, 2);

    expect(notified, 1);
  });

  test('a release with nothing reported notifies no one', () async {
    waiting.release(Object());
    await _flush();

    expect(notified, 0);
  });

  test(
    "a release whose notify comes due after dispose doesn't throw",
    () async {
      // The app disposes it after the hosts below it, whose releases notify
      // a microtask later. Notifying a disposed ChangeNotifier asserts, and
      // here that would surface as an uncaught error after the flush.
      final early = SessionSyncWaiting();
      final owner = Object();
      early
        ..report(owner, 1)
        ..release(owner)
        ..dispose();

      await _flush();
    },
  );

  testWidgets('release notifies after the current frame, not during it', (
    tester,
  ) async {
    final owner = Object();
    Widget app({required bool session}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          ValueListenableBuilder<int?>(
            valueListenable: waiting,
            builder: (_, count, _) => Text('waiting: ${count ?? 'none'}'),
          ),
          if (session) _ReleasesOnDispose(waiting: waiting, owner: owner),
        ],
      ),
    );
    await tester.pumpWidget(app(session: true));
    waiting.report(owner, 2);
    await tester.pump();
    expect(find.text('waiting: 2'), findsOneWidget);

    await tester.pumpWidget(app(session: false));

    expect(tester.takeException(), isNull);
    expect(waiting.value, isNull);
    await tester.pump();
    expect(find.text('waiting: none'), findsOneWidget);
  });

  testWidgets("a session's host leaving after the next one reported keeps "
      "the next one's count", (tester) async {
    void onStatus(Object owner, SessionSyncStatus? status) => status == null
        ? waiting.release(owner)
        : waiting.report(owner, status.waiting ?? 0);
    final departing = _Queue(2);
    final arriving = _Queue(5);
    Widget hosts({required bool old, required bool next}) => Column(
      children: [
        if (old)
          SyncStatusScopeHost(
            key: const ValueKey('departing'),
            queue: departing,
            onStatus: onStatus,
            child: const SizedBox.shrink(),
          ),
        if (next)
          SyncStatusScopeHost(
            key: const ValueKey('arriving'),
            queue: arriving,
            onStatus: onStatus,
            child: const SizedBox.shrink(),
          ),
      ],
    );

    await tester.pumpWidget(hosts(old: true, next: false));
    await tester.pump();
    expect(waiting.value, 2);
    await tester.pumpWidget(hosts(old: true, next: true));
    await tester.pump();
    expect(waiting.value, 5);

    await tester.pumpWidget(hosts(old: false, next: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(waiting.value, 5);

    await tester.pumpWidget(hosts(old: false, next: false));
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(waiting.value, isNull);
  });
}
