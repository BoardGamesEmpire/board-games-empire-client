import 'dart:async';

import 'package:hydration/hydration.dart';
import 'package:interfaces/orchestration.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:test/test.dart';

enum _Outcome { complete, partial, failed }

bool _landed(_Outcome o) => o != _Outcome.failed;

const _loggerName = 'bge.hydration.test';

/// Answers [confirm] with [answer], or throws [throws] when one is set,
/// recording whom it was asked about (#432).
class _FakeGuard implements SessionIdentityGuard {
  SessionConfirmation answer = SessionConfirmation.confirmed;
  Object? throws;
  final askedFor = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    askedFor.add(userId);
    final error = throws;
    if (error != null) throw error;
    return answer;
  }
}

/// A drain held open until the test ends it: one completer per call.
class _FakeDrain {
  final calls = <Completer<_Outcome>>[];

  int get count => calls.length;

  Future<_Outcome> call() {
    final drain = Completer<_Outcome>();
    calls.add(drain);
    return drain.future;
  }

  void complete(_Outcome outcome) => calls.last.complete(outcome);
}

/// Records what a pass registers with it (#302).
class _FakeRehydrator implements SessionRehydrator {
  final keys = <String>[];
  late bool Function() isStale;
  late Future<void> Function() run;

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {
    keys.add(key);
    this.isStale = isStale;
    this.run = run;
  }

  @override
  Future<void> rehydrateStale() => throw UnimplementedError();
}

/// Resolves what a test registered, by type, and nothing else.
class _FakeContainer implements DependencyContainer {
  _FakeContainer([this._registered = const {}]);

  final Map<Type, Object> _registered;

  @override
  bool isRegistered<T extends Object>() => _registered.containsKey(T);

  @override
  T get<T extends Object>() {
    final instance = _registered[T];
    if (instance == null) throw StateError('$T is not registered');
    return instance as T;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late DateTime clock;
  late HydrationStatus<_Outcome> status;
  late _FakeGuard guard;
  late _FakeDrain drain;

  setUp(() {
    clock = DateTime.utc(2026, 10, 27, 12);
    status = HydrationStatus<_Outcome>(landed: _landed, now: () => clock);
    guard = _FakeGuard();
    drain = _FakeDrain();
  });
  tearDown(() async => status.close());

  HydratePass<_Outcome> build({
    bool guarded = true,
    Future<_Outcome> Function()? drainWith,
  }) => HydratePass<_Outcome>(
    feature: 'Feature',
    drain: drainWith ?? drain.call,
    status: status,
    failed: _Outcome.failed,
    userId: 'user-1',
    logger: BgeLogger(_loggerName),
    guard: guarded ? guard : null,
    context: const {'serverId': 's-1'},
  );

  /// This suite's log records, captured off [Logger.root] as the auth
  /// suite does (delivery is synchronous), with the root level restored
  /// afterwards.
  List<LogRecord> captureLogs() {
    final records = <LogRecord>[];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen((r) {
      if (r.loggerName == _loggerName) records.add(r);
    });
    addTearDown(() async {
      await sub.cancel();
      Logger.root.level = previous;
    });
    return records;
  }

  /// Expects [records] to hold exactly one line, at [level], reading
  /// [message], with the caller's context and the error that caused it.
  void expectOneLine(
    List<LogRecord> records, {
    required Level level,
    required String message,
  }) {
    expect(records, hasLength(1));
    final record = records.single;
    expect(record.level, level);
    expect(record.message, message);
    expect((record.object! as ContextLogMessage).context, {'serverId': 's-1'});
    expect(record.error, isA<StateError>());
  }

  group('one drain at a time', () {
    test('a call while a drain runs joins it and gets its outcome', () async {
      final pass = build();

      final first = pass.run();
      final second = pass.run();
      await pumpEventQueue();
      drain.complete(_Outcome.partial);

      expect(drain.count, 1);
      expect(await first, _Outcome.partial);
      expect(await second, _Outcome.partial);
    });

    test('once a drain settles, the next call starts another', () async {
      final pass = build();
      final first = pass.run();
      await pumpEventQueue();
      drain.complete(_Outcome.complete);
      await first;

      final second = pass.run();
      await pumpEventQueue();
      drain.complete(_Outcome.complete);
      await second;

      expect(drain.count, 2);
    });

    test('the status reads running before run returns', () async {
      final pass = build();

      final running = pass.run();

      // A screen built before the drain's first turn must not read idle
      // (#269).
      expect(status.state, HydrationState.running);

      await pumpEventQueue();
      drain.complete(_Outcome.complete);
      await running;
    });

    test(
      'settled completes at once with nothing in flight, else when the drain '
      'ends',
      () async {
        final pass = build();

        var idle = false;
        unawaited(pass.settled.then((_) => idle = true));
        await pumpEventQueue();
        expect(idle, isTrue);

        unawaited(pass.run());
        await pumpEventQueue();
        var settled = false;
        // A caller after a local write waits out the drain in flight, then
        // asks for one of its own; it must not be handed the old one again.
        final after = pass.settled.then((_) {
          settled = true;
          return pass.run();
        });
        await pumpEventQueue();
        expect(settled, isFalse);

        drain.complete(_Outcome.complete);
        await pumpEventQueue();
        expect(settled, isTrue);
        expect(drain.count, 2);

        drain.complete(_Outcome.complete);
        await after;
      },
    );

    test('runAfterSettled runs at once with nothing in flight, else waits out '
        'the drain and starts its own', () async {
      final pass = build();

      final first = pass.runAfterSettled();
      await pumpEventQueue();
      expect(drain.count, 1);
      drain.complete(_Outcome.complete);
      expect(await first, _Outcome.complete);

      unawaited(pass.run());
      await pumpEventQueue();
      final after = pass.runAfterSettled();
      await pumpEventQueue();
      expect(drain.count, 2, reason: 'joined nothing, started nothing yet');

      drain.complete(_Outcome.complete);
      await pumpEventQueue();
      expect(drain.count, 3);

      drain.complete(_Outcome.partial);
      expect(await after, _Outcome.partial);
    });
  });

  group('the first session check (#563)', () {
    test(
      'asks about the scope user once per drain, before it starts',
      () async {
        final pass = build();

        final first = pass.run();
        expect(guard.askedFor, ['user-1']);
        expect(drain.count, 0);

        final second = pass.run();
        await pumpEventQueue();

        expect(guard.askedFor, ['user-1']);
        expect(drain.count, 1);

        drain.complete(_Outcome.complete);
        await Future.wait([first, second]);
      },
    );

    for (final answer in [
      SessionConfirmation.notThisUser,
      SessionConfirmation.unanswered,
    ]) {
      test('a call joining a running drain reports nothing before that drain ends, '
          'whatever the guard answers: ${answer.name}', () async {
        final pass = build();
        final readings = <Hydration>[];
        final sub = status.watch().listen(readings.add);
        addTearDown(sub.cancel);

        final first = pass.run();
        await pumpEventQueue();

        // A retry pressed mid-drain, by now refused: it must neither report
        // failed over the drain still running nor start one of its own.
        guard.answer = answer;
        var secondDone = false;
        final second = pass.run();
        unawaited(second.then((_) => secondDone = true));
        await pumpEventQueue();

        expect(readings, [
          const Hydration(),
          const Hydration(state: HydrationState.running),
        ]);
        expect(secondDone, isFalse);
        expect(guard.askedFor.length, 1);

        drain.complete(_Outcome.complete);

        expect(await first, _Outcome.complete);
        expect(await second, _Outcome.complete);
        await pumpEventQueue();
        expect(
          readings.last,
          const Hydration(state: HydrationState.refreshed, everRefreshed: true),
        );
      });
    }

    for (final answer in [
      SessionConfirmation.notThisUser,
      SessionConfirmation.unanswered,
    ]) {
      test('a refused check with nothing in flight starts no drain and '
          'reports failed: ${answer.name}', () async {
        guard.answer = answer;

        expect(await build().run(), _Outcome.failed);
        expect(drain.count, 0);
        expect(status.state, HydrationState.failed);
      });
    }

    test('a refused check logs which answer it got', () async {
      final records = captureLogs();

      guard.answer = SessionConfirmation.notThisUser;
      await build().run();

      expect(records, hasLength(1));
      expect(records.single.level, Level.INFO);
      expect((records.single.object! as ContextLogMessage).context, {
        'serverId': 's-1',
        'answer': 'notThisUser',
      });
    });

    test(
      'a guard that throws ends the drain failed, and run does not throw',
      () async {
        final records = captureLogs();
        guard.throws = StateError('x');

        expect(await build().run(), _Outcome.failed);
        expect(status.state, HydrationState.failed);
        expect(drain.count, 0);
        expectOneLine(
          records,
          level: Level.WARNING,
          message: 'Feature hydrate held off: the session could not be checked',
        );
      },
    );

    test('no guard is a confirmed session', () async {
      final pass = build(guarded: false);

      final result = pass.run();
      await pumpEventQueue();
      drain.complete(_Outcome.complete);

      expect(await result, _Outcome.complete);
      expect(guard.askedFor, isEmpty);
      expect(status.state, HydrationState.refreshed);
    });
  });

  group('failures never escape', () {
    test('a drain that throws reports failed', () async {
      final records = captureLogs();
      final pass = build();

      final result = pass.run();
      await pumpEventQueue();
      drain.calls.single.completeError(StateError('boom'));

      expect(await result, _Outcome.failed);
      expect(status.state, HydrationState.failed);
      expectOneLine(
        records,
        level: Level.SEVERE,
        message: 'Feature hydrate escaped its own error handling',
      );
    });

    test('a drain that throws before returning a future reports failed '
        'too', () async {
      final records = captureLogs();
      // A drain that is not an async function throws rather than returning
      // a failed future, which a catchError on that future would never see.
      final pass = build(drainWith: () => throw StateError('boom'));

      expect(await pass.run(), _Outcome.failed);
      expect(status.state, HydrationState.failed);
      expectOneLine(
        records,
        level: Level.SEVERE,
        message: 'Feature hydrate escaped its own error handling',
      );
    });

    test(
      'a drain finishing after the status closed settles without throwing',
      () async {
        final pass = build();

        final result = pass.run();
        await pumpEventQueue();
        await status.close();
        drain.complete(_Outcome.complete);

        expect(await result, _Outcome.complete);
        await pass.settled;
      },
    );
  });

  group('markStale during a drain (#407)', () {
    test('a call joining after markStale leaves the drain unstamped', () async {
      final pass = build();

      final first = pass.run();
      await pumpEventQueue();
      // A create reached the server after the drain may have read it. The
      // call that follows it joins that drain and must not forgive it.
      status.markStale();
      final second = pass.run();
      drain.complete(_Outcome.complete);
      await Future.wait([first, second]);

      expect(drain.count, 1);
      expect(status.state, HydrationState.refreshed);
      expect(status.isStaleAfter(const Duration(minutes: 5)), isTrue);
    });
  });

  group('registerRehydrate', () {
    const window = Duration(minutes: 5);

    late _FakeRehydrator rehydrator;
    late _FakeContainer container;

    setUp(() {
      rehydrator = _FakeRehydrator();
      container = _FakeContainer({SessionRehydrator: rehydrator});
    });

    test('registers the name, and run starts a pass', () async {
      build().registerRehydrate(container, 'feature', staleAfter: window);

      expect(rehydrator.keys, ['feature']);

      final run = rehydrator.run();
      expect(status.state, HydrationState.running);
      await pumpEventQueue();
      expect(drain.count, 1);

      drain.complete(_Outcome.complete);
      await run;
      expect(status.state, HydrationState.refreshed);
    });

    test(
      'isStale: idle and failed are stale, running is not, refreshed ages out '
      'at the window',
      () async {
        final pass = build()
          ..registerRehydrate(container, 'feature', staleAfter: window);

        expect(rehydrator.isStale(), isTrue, reason: 'idle');

        var running = pass.run();
        expect(rehydrator.isStale(), isFalse, reason: 'running');
        await pumpEventQueue();
        drain.complete(_Outcome.failed);
        await running;
        expect(rehydrator.isStale(), isTrue, reason: 'failed');

        running = pass.run();
        await pumpEventQueue();
        drain.complete(_Outcome.complete);
        await running;
        expect(rehydrator.isStale(), isFalse, reason: 'just refreshed');

        clock = clock.add(window - const Duration(seconds: 1));
        expect(rehydrator.isStale(), isFalse, reason: 'inside the window');

        clock = clock.add(const Duration(seconds: 1));
        expect(rehydrator.isStale(), isTrue, reason: 'at the window');

        // Running is answered by state, however old the last answer is.
        running = pass.run();
        expect(rehydrator.isStale(), isFalse, reason: 'running, aged');
        await pumpEventQueue();
        drain.complete(_Outcome.complete);
        await running;
      },
    );

    test('no rehydrator registered is a no-op', () {
      expect(
        () => build().registerRehydrate(
          _FakeContainer(),
          'feature',
          staleAfter: window,
        ),
        returnsNormally,
      );
      expect(drain.count, 0);
      expect(status.state, HydrationState.idle);
    });
  });
}
