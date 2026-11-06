import 'dart:async';

import 'package:bge_test_support/waits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydration/hydration.dart';

/// A status whose outcome is whether the pass landed rows.
HydrationStatus<bool> _status() => HydrationStatus<bool>(landed: (l) => l);

/// A [_status] that counts the watches still listening to it, so a test can
/// see what a wait left behind.
class _CountedStatus extends HydrationStatus<bool> {
  _CountedStatus() : super(landed: (l) => l);

  int listening = 0;

  @override
  Stream<Hydration> watch() {
    final readings = super.watch();
    late final StreamSubscription<Hydration> forwarding;
    late final StreamController<Hydration> out;
    out = StreamController<Hydration>(
      onListen: () {
        listening++;
        forwarding = readings.listen(out.add, onDone: out.close);
      },
      onCancel: () {
        listening--;
        return forwarding.cancel();
      },
    );
    return out.stream;
  }
}

void main() {
  group('pollUntil', () {
    test('returns once the condition holds', () async {
      var checks = 0;

      await pollUntil(() => ++checks == 3, describe: () => 'never held');

      expect(checks, 3);
    });

    test(
      'fails at its deadline on a check that never answers',
      () async {
        await expectLater(
          pollUntil(
            () => Completer<bool>().future,
            describe: () => 'the check never answered',
            timeout: const Duration(milliseconds: 50),
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              'the check never answered',
            ),
          ),
        );
      },
      // Without the bound the check hangs: fail in seconds, not at the
      // runner's default.
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });

  group('awaitRefreshed', () {
    // Each case runs with the status that acts first at either end of the
    // map, so a wait that watched only the first status, or only the last,
    // fails one of them.
    for (final (first, second) in [('a', 'b'), ('b', 'a')]) {
      test('returns once every status has landed a pass, $first '
          'first', () async {
        final statuses = {'a': _status(), 'b': _status()};
        var returned = false;

        unawaited(awaitRefreshed(statuses).then((_) => returned = true));
        statuses[first]!
          ..started()
          ..finished(true);
        await pumpEventQueue();
        expect(returned, isFalse, reason: '$second has not landed yet');

        statuses[second]!
          ..started()
          ..finished(true);
        await pumpEventQueue();
        expect(returned, isTrue);
      });
    }

    for (final failingFirst in [true, false]) {
      test(
        'fails at once, naming the status, when a pass fails, the failing '
        'status ${failingFirst ? 'first' : 'last'}',
        () async {
          final landed = _status();
          final failing = _status();

          final waiting = awaitRefreshed(
            failingFirst
                ? {'failing': failing, 'landed': landed}
                : {'landed': landed, 'failing': failing},
          );
          failing
            ..started()
            ..finished(false);

          await expectLater(
            waiting,
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'failing failed its pass instead of landing it',
              ),
            ),
          );
        },
        // The default ten-second timeout would also fail this, later: bound
        // the test well under it so only the fast failure passes.
        timeout: const Timeout(Duration(seconds: 2)),
      );
    }

    test('fails at its timeout, naming the status and its state', () async {
      final ran = _status()
        ..started()
        ..finished(true);

      await expectLater(
        awaitRefreshed({
          'ran': ran,
          'never ran': _status(),
        }, timeout: const Duration(milliseconds: 50)),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            'never ran never landed a pass; it was left idle',
          ),
        ),
      );
    });

    group('stops watching every status when it', () {
      test('returns', () async {
        final a = _CountedStatus();
        final b = _CountedStatus();

        final waiting = awaitRefreshed({'a': a, 'b': b});
        for (final status in [a, b]) {
          status
            ..started()
            ..finished(true);
        }
        await waiting;

        expect([a.listening, b.listening], [0, 0]);
      });

      test('fails on a failed pass', () async {
        final pending = _CountedStatus();
        final failing = _CountedStatus();

        final waiting = awaitRefreshed({
          'pending': pending,
          'failing': failing,
        });
        failing
          ..started()
          ..finished(false);
        await expectLater(waiting, throwsStateError);

        expect(
          pending.listening,
          0,
          reason: 'the status still waited on kept its watch',
        );
      });

      test('times out', () async {
        final pending = _CountedStatus();

        await expectLater(
          awaitRefreshed({
            'pending': pending,
          }, timeout: const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()),
        );

        expect(pending.listening, 0);
      });
    });
  });
}
