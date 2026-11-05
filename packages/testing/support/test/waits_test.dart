import 'dart:async';

import 'package:bge_test_support/waits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydration/hydration.dart';

/// A status whose outcome is whether the pass landed rows.
HydrationStatus<bool> _status() => HydrationStatus<bool>(landed: (l) => l);

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
    test('returns once every status has landed a pass', () async {
      final a = _status();
      final b = _status();
      var returned = false;

      unawaited(
        awaitRefreshed({'a': a, 'b': b}).then((_) => returned = true),
      );
      a
        ..started()
        ..finished(true);
      await pumpEventQueue();
      expect(returned, isFalse, reason: 'b has not landed yet');

      b
        ..started()
        ..finished(true);
      await pumpEventQueue();
      expect(returned, isTrue);
    });

    test(
      'fails at once, naming the status, when a pass fails',
      () async {
        final landed = _status();
        final failing = _status();

        final waiting = awaitRefreshed({
          'landed': landed,
          'failing': failing,
        });
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
  });
}
