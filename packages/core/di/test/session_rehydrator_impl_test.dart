import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';

/// A registrable entry whose staleness and completion the test drives.
class _Entry {
  _Entry({this.stale = true});

  bool stale;
  int runs = 0;
  Completer<void>? gate;
  Object? throwOnRun;

  bool isStale() => stale;

  Future<void> run() async {
    runs++;
    if (throwOnRun != null) throw throwOnRun!;
    final gate = this.gate;
    if (gate != null) await gate.future;
  }
}

void main() {
  late SessionRehydratorImpl rehydrator;

  setUp(() => rehydrator = SessionRehydratorImpl());

  void add(String key, _Entry entry) =>
      rehydrator.register(key, isStale: entry.isStale, run: entry.run);

  group('SessionRehydratorImpl — what a pass re-runs (#302 D4)', () {
    test('runs an entry that reports itself stale', () async {
      final entry = _Entry();
      add('household', entry);

      await rehydrator.rehydrateStale();

      expect(entry.runs, equals(1));
    });

    test('leaves a fresh entry alone', () async {
      final fresh = _Entry(stale: false);
      add('household', fresh);

      await rehydrator.rehydrateStale();

      expect(fresh.runs, isZero);
    });

    test('asks each entry again on every pass, rather than caching the '
        'first answer', () async {
      final entry = _Entry(stale: false);
      add('household', entry);

      await rehydrator.rehydrateStale();
      entry.stale = true;
      await rehydrator.rehydrateStale();

      expect(entry.runs, equals(1));
    });

    test('runs every stale entry, not just the first', () async {
      final first = _Entry();
      final second = _Entry();
      add('household', first);
      add('collection', second);

      await rehydrator.rehydrateStale();

      expect(first.runs, equals(1));
      expect(second.runs, equals(1));
    });

    test('a pass with nothing registered is a no-op, not an error', () async {
      await expectLater(rehydrator.rehydrateStale(), completes);
    });
  });

  group('SessionRehydratorImpl — one pass at a time (#302 D3)', () {
    test('a pass triggered while one is in flight joins it rather than '
        'running the entries twice', () async {
      final entry = _Entry()..gate = Completer<void>();
      add('household', entry);

      final first = rehydrator.rehydrateStale();
      final second = rehydrator.rehydrateStale();
      entry.gate!.complete();
      await Future.wait([first, second]);

      expect(entry.runs, equals(1));
    });

    test(
      'a pass after the previous one settled runs the entries again',
      () async {
        final entry = _Entry();
        add('household', entry);

        await rehydrator.rehydrateStale();
        await rehydrator.rehydrateStale();

        expect(entry.runs, equals(2));
      },
    );

    test('an entry registered mid-pass is picked up by the next one, not '
        'the running one', () async {
      final running = _Entry()..gate = Completer<void>();
      add('household', running);
      final pass = rehydrator.rehydrateStale();

      final late = _Entry();
      add('collection', late);
      running.gate!.complete();
      await pass;

      expect(late.runs, isZero);

      await rehydrator.rehydrateStale();
      expect(late.runs, equals(1));
    });
  });

  group('SessionRehydratorImpl — a pass never throws', () {
    test('a throwing entry does not fail the pass', () async {
      final thrower = _Entry()..throwOnRun = StateError('boom');
      add('household', thrower);

      await expectLater(rehydrator.rehydrateStale(), completes);
    });

    test('a throwing entry does not stop the entries after it', () async {
      final thrower = _Entry()..throwOnRun = StateError('boom');
      final healthy = _Entry();
      add('household', thrower);
      add('collection', healthy);

      await rehydrator.rehydrateStale();

      expect(healthy.runs, equals(1));
    });

    test(
      'a throwing entry does not wedge the guard against later passes',
      () async {
        final thrower = _Entry()..throwOnRun = StateError('boom');
        add('household', thrower);

        await rehydrator.rehydrateStale();
        await rehydrator.rehydrateStale();

        expect(thrower.runs, equals(2));
      },
    );

    test('a staleness check that throws is treated as not stale', () async {
      rehydrator.register(
        'household',
        isStale: () => throw StateError('boom'),
        run: () async => fail('a broken staleness check must not run a pass'),
      );

      await expectLater(rehydrator.rehydrateStale(), completes);
    });
  });

  group('SessionRehydratorImpl — after the session ends', () {
    test('a pass triggered after close runs nothing', () async {
      final entry = _Entry();
      add('household', entry);

      await rehydrator.close();
      await rehydrator.rehydrateStale();

      expect(entry.runs, isZero);
    });

    test('close is idempotent', () async {
      await rehydrator.close();
      await expectLater(rehydrator.close(), completes);
    });

    test('registering after close is dropped rather than throwing', () async {
      await rehydrator.close();

      expect(() => add('household', _Entry()), returnsNormally);
    });

    test('close during a pass lets the in-flight entry settle', () async {
      final entry = _Entry()..gate = Completer<void>();
      add('household', entry);

      final pass = rehydrator.rehydrateStale();
      await rehydrator.close();
      entry.gate!.complete();

      await expectLater(pass, completes);
    });
  });

  group('SessionRehydratorImpl — registration is explicit', () {
    test('a duplicate key is a wiring bug, not a silent overwrite', () {
      add('household', _Entry());

      expect(() => add('household', _Entry()), throwsArgumentError);
    });

    test('the rejected duplicate does not displace the original', () async {
      final original = _Entry();
      add('household', original);
      try {
        add('household', _Entry());
      } on ArgumentError {
        // The point of the test is what survives the throw.
      }

      await rehydrator.rehydrateStale();

      expect(original.runs, equals(1));
    });
  });
}
