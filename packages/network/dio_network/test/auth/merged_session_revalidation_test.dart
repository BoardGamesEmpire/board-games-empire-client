import 'dart:async';

import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';

void main() {
  group('MergedSessionRevalidation', () {
    test('is a SessionRejectionSignal', () {
      expect(
        MergedSessionRevalidation(() async => null),
        isA<SessionRejectionSignal>(),
      );
    });

    test(
      'concurrent reports of a gone session share one revalidation',
      () async {
        final gate = Completer<Object?>();
        var calls = 0;
        final signal = MergedSessionRevalidation(() {
          calls++;
          return gate.future;
        });

        final reports = [for (var i = 0; i < 5; i++) signal.report()];
        var completed = 0;
        for (final report in reports) {
          unawaited(report.then((_) => completed++));
        }

        await pumpEventQueue();
        expect(calls, 1);
        expect(completed, 0, reason: 'all five wait on the one revalidation');

        gate.complete(null);
        await Future.wait(reports);

        expect(calls, 1, reason: 'no session: the queued re-read is skipped');
        expect(completed, 5);
      },
    );

    test(
      'reports during a re-read that finds a session share one more, '
      'started after it settles',
      () async {
        // The running re-read may have been answered before the server
        // revoked the session these later 401s saw.
        final gates = <Completer<Object?>>[];
        final signal = MergedSessionRevalidation(() {
          gates.add(Completer<Object?>());
          return gates.last.future;
        });

        var firstDone = false;
        unawaited(signal.report().then((_) => firstDone = true));
        var laterDone = 0;
        final later = [for (var i = 0; i < 4; i++) signal.report()];
        for (final report in later) {
          unawaited(report.then((_) => laterDone++));
        }
        await pumpEventQueue();
        expect(gates, hasLength(1));

        gates[0].complete('a session');
        await pumpEventQueue();
        expect(firstDone, isTrue);
        expect(gates, hasLength(2), reason: 'one queued re-read for all four');
        expect(laterDone, 0, reason: 'they wait for the queued re-read');

        gates[1].complete(null);
        await Future.wait(later);
        expect(gates, hasLength(2));
        expect(laterDone, 4);
      },
    );

    test('a report during the queued re-read queues behind it', () async {
      final gates = <Completer<Object?>>[];
      final signal = MergedSessionRevalidation(() {
        gates.add(Completer<Object?>());
        return gates.last.future;
      });

      unawaited(signal.report());
      final queued = signal.report();
      gates[0].complete('a session');
      await pumpEventQueue();
      expect(gates, hasLength(2));

      final behindQueued = signal.report();
      gates[1].complete('a session');
      await queued;
      await pumpEventQueue();
      expect(gates, hasLength(3));

      gates[2].complete('a session');
      await behindQueued;
      expect(gates, hasLength(3));
    });

    test('a re-read that failed still runs the queued one', () async {
      var calls = 0;
      final first = Completer<Object?>();
      final signal = MergedSessionRevalidation(() {
        calls++;
        return calls == 1 ? first.future : Future.value();
      });

      unawaited(signal.report());
      final queued = signal.report();
      first.completeError(StateError('network down'));

      await expectLater(queued, completes);
      expect(calls, 2, reason: 'a failure says nothing about the session');
    });

    test('a report after settling starts a new revalidation', () async {
      var calls = 0;
      final signal = MergedSessionRevalidation(() async {
        calls++;
        return null;
      });

      await signal.report();
      await signal.report();

      expect(calls, 2);
    });

    test('a throwing revalidate completes report normally', () async {
      var calls = 0;
      final signal = MergedSessionRevalidation(() async {
        calls++;
        throw StateError('network down');
      });

      await expectLater(signal.report(), completes);
      expect(calls, 1);

      await expectLater(signal.report(), completes);
      expect(calls, 2, reason: 'a failed revalidation does not stick');
    });

    test('a revalidate that throws synchronously completes normally', () async {
      var calls = 0;
      final signal = MergedSessionRevalidation(() {
        calls++;
        throw StateError('sync failure');
      });

      await expectLater(signal.report(), completes);
      await expectLater(signal.report(), completes);
      expect(calls, 2);
    });
  });
}
