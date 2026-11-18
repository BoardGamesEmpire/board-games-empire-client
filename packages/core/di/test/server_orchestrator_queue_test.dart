import 'dart:async';

import 'package:di/di.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'support/orchestrator_test_fixtures.dart';

/// The preferences every orchestrator here reads, so the backgrounding
/// timeout below is the one its timers use.
const _kPrefs = DevicePreferences();

/// Just past a backgrounding timer's expiry. `stubbedOrchestrator` runs as
/// desktop.
final _pastExpiry = Duration(
  seconds: _kPrefs.backgroundingTimeoutSeconds(isDesktop: true) + 1,
);

/// Pins the orchestrator's lifecycle command queue (#174): a call made while
/// another command runs waits for it, commands run in call order, a timer's
/// expiry is a queued command that re-checks its transition when it runs,
/// and a call made from inside a running command fails fast.
void main() {
  setUpAll(() {
    registerFallbackValue(ConnectionState.disconnected);
  });

  test('a backgrounded server suspends when its timer expires', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B', makeActive: true));
      final a = _context(orchestrator, 'A');

      async.elapse(_pastExpiry);

      verify(a.suspend).called(1);
      verify(
        () => repo.updateConnectionState(
          serverId: 'A',
          newState: ConnectionState.monitoring,
        ),
      ).called(1);
    });
  });

  test(
    'a switch made while another command runs waits for it instead of '
    'throwing',
    () {
      _run((async, repo, orchestrator) {
        _settle(async, orchestrator.connectServer('A'));
        _settle(async, orchestrator.connectServer('B'));
        final release = Completer<void>();
        gate(_context(orchestrator, 'B'), #activate, release);

        final toB = _Outcome(orchestrator.switchActiveServer('B'));
        final toA = _Outcome(orchestrator.switchActiveServer('A'));
        async.flushMicrotasks();
        expect(toA.error, isNull);
        expect(toB.isDone || toA.isDone, isFalse);

        release.complete();
        async.flushMicrotasks();

        expect(toB.isDone && toA.isDone, isTrue);
        expect(toB.error, isNull);
        expect(toA.error, isNull);
        expect(orchestrator.activeServerId, 'A');
      });
    },
  );

  test('an initialize queued behind the first fails once it finishes', () {
    fakeAsync((async) {
      final (:repo, :prefsRepo, :orchestrator) = stubbedOrchestrator();
      when(prefsRepo.get).thenAnswer((_) async => _kPrefs);
      when(repo.getConnectedServers).thenAnswer(
        (_) async => [testServerConfig(id: 'A', state: ConnectionState.active)],
      );

      final first = _Outcome(orchestrator.initialize());
      final second = _Outcome(orchestrator.initialize());
      async.flushMicrotasks();

      expect(first.error, isNull);
      expect(
        second.error,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'ServerOrchestrator is already initialized.',
        ),
      );
      verify(repo.getConnectedServers).called(1);
      expect(orchestrator.activeServerId, 'A');

      _settle(async, orchestrator.dispose());
    });
  });

  test('commands run in the order they were called', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B'));
      _settle(async, orchestrator.connectServer('C'));

      // B's activation is held, so a command that didn't wait for it would
      // record its own activation first.
      final release = Completer<void>();
      final activated = <String>[];
      for (final id in ['A', 'B', 'C']) {
        final ctx = _context(orchestrator, id);
        when(ctx.activate).thenAnswer((_) async {
          if (id == 'B') await release.future;
          activated.add(id);
          when(() => ctx.state).thenReturn(ServerContextState.active);
        });
      }

      final switches = [
        for (final id in ['B', 'C', 'A'])
          _Outcome(orchestrator.switchActiveServer(id)),
      ];
      async.flushMicrotasks();
      expect(activated, isEmpty);

      release.complete();
      async.flushMicrotasks();

      expect(activated, ['B', 'C', 'A']);
      expect([for (final s in switches) s.error], everyElement(isNull));
      expect(orchestrator.activeServerId, 'A');
    });
  });

  test('an expiry queued behind a switch to its server is dropped', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B', makeActive: true));
      final a = _context(orchestrator, 'A');
      expect(a.state, ServerContextState.backgrounding);

      // Hold an unrelated command, so the switch and then the expiry queue
      // behind it.
      final release = Completer<void>();
      when(() => repo.getServer('C')).thenAnswer((_) async {
        await release.future;
        return testServerConfig(id: 'C');
      });
      final connectC = _Outcome(orchestrator.connectServer('C'));
      final toA = _Outcome(orchestrator.switchActiveServer('A'));
      async.elapse(_pastExpiry);
      expect(toA.isDone, isFalse);

      release.complete();
      async.flushMicrotasks();

      expect(connectC.error, isNull);
      expect(toA.error, isNull);
      verifyNever(a.suspend);
      expect(orchestrator.activeServerId, 'A');
      expect(a.state, ServerContextState.active);
    });
  });

  test('an expiry whose timer restarted while it waited is dropped', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B', makeActive: true));
      final a = _context(orchestrator, 'A');

      final release = Completer<void>();
      when(() => repo.getServer('C')).thenAnswer((_) async {
        await release.future;
        return testServerConfig(id: 'C');
      });
      final connectC = _Outcome(orchestrator.connectServer('C'));
      // A goes back to backgrounding under a fresh timer before the stale
      // expiry runs, so only the timer's generation tells them apart.
      final toA = _Outcome(orchestrator.switchActiveServer('A'));
      final toB = _Outcome(orchestrator.switchActiveServer('B'));
      async.elapse(_pastExpiry);

      release.complete();
      async.flushMicrotasks();

      expect([connectC.error, toA.error, toB.error], everyElement(isNull));
      expect(a.state, ServerContextState.backgrounding);
      verifyNever(a.suspend);

      async.elapse(_pastExpiry);

      verify(a.suspend).called(1);
    });
  });

  test(
    'a suspend in flight finishes before a switch to that server activates '
    'it',
    () {
      _run((async, repo, orchestrator) {
        _settle(async, orchestrator.connectServer('A'));
        _settle(async, orchestrator.connectServer('B', makeActive: true));
        final a = _context(orchestrator, 'A');
        final release = Completer<void>();
        gate(a, #suspend, release);
        clearInteractions(a);

        async.elapse(_pastExpiry);
        final toA = _Outcome(orchestrator.switchActiveServer('A'));
        async.flushMicrotasks();
        expect(toA.isDone, isFalse);

        release.complete();
        async.flushMicrotasks();

        expect(toA.isDone, isTrue);
        expect(toA.error, isNull);
        verifyInOrder([a.suspend, a.activate]);
        expect(orchestrator.activeServerId, 'A');
        expect(a.state, ServerContextState.active);
      });
    },
  );

  test('a call from inside a running command fails fast', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B'));
      final b = _context(orchestrator, 'B');
      Object? reentryError;
      when(b.activate).thenAnswer((_) async {
        try {
          await orchestrator.switchActiveServer('A');
        } on Object catch (e) {
          reentryError = e;
        }
        when(() => b.state).thenReturn(ServerContextState.active);
      });

      // Settles, so the inner call didn't wait on the command it ran in.
      _settle(async, orchestrator.switchActiveServer('B'));

      expect(
        reentryError,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Re-entrant orchestrator call from inside a running lifecycle '
              'command.',
        ),
      );
      expect(orchestrator.activeServerId, 'B');
    });
  });

  test('dispose from inside a running command fails fast', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B'));
      final b = _context(orchestrator, 'B');
      Object? reentryError;
      when(b.activate).thenAnswer((_) async {
        try {
          await orchestrator.dispose();
        } on Object catch (e) {
          reentryError = e;
        }
        when(() => b.state).thenReturn(ServerContextState.active);
      });

      // Settles, so the inner dispose didn't wait on the command it ran in.
      _settle(async, orchestrator.switchActiveServer('B'));

      expect(
        reentryError,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Re-entrant orchestrator call from inside a running lifecycle '
              'command.',
        ),
      );
      expect(orchestrator.activeServerId, 'B');

      // The refused call disposed nothing: a later dispose still tears down.
      _settle(async, orchestrator.dispose());
      verify(b.dispose).called(1);
    });
  });

  // A context's activation starts services that outlive the command: sync
  // engines, listeners, timers. Each runs in the zone it was started in.
  group('a call from work a finished command started', () {
    /// Stubs B's activation to start a one-second timer that switches to A,
    /// and returns where that switch's outcome lands.
    List<_Outcome> switchBackLater(ServerOrchestratorImpl orchestrator) {
      final later = <_Outcome>[];
      final b = _context(orchestrator, 'B');
      when(b.activate).thenAnswer((_) async {
        Timer(const Duration(seconds: 1), () {
          later.add(_Outcome(orchestrator.switchActiveServer('A')));
        });
        when(() => b.state).thenReturn(ServerContextState.active);
      });
      return later;
    }

    test('runs as a command of its own', () {
      _run((async, repo, orchestrator) {
        _settle(async, orchestrator.connectServer('A'));
        _settle(async, orchestrator.connectServer('B'));
        final later = switchBackLater(orchestrator);
        _settle(async, orchestrator.switchActiveServer('B'));
        expect(orchestrator.activeServerId, 'B');

        async.elapse(const Duration(seconds: 1));

        expect(later.single.isDone, isTrue);
        expect(later.single.error, isNull);
        expect(orchestrator.activeServerId, 'A');
      });
    });

    test('waits for another command that is running', () {
      _run((async, repo, orchestrator) {
        _settle(async, orchestrator.connectServer('A'));
        _settle(async, orchestrator.connectServer('B'));
        final later = switchBackLater(orchestrator);
        _settle(async, orchestrator.switchActiveServer('B'));

        final release = Completer<void>();
        when(() => repo.getServer('C')).thenAnswer((_) async {
          await release.future;
          return testServerConfig(id: 'C');
        });
        final connectC = _Outcome(orchestrator.connectServer('C'));
        async.elapse(const Duration(seconds: 1));
        expect(later.single.isDone, isFalse);
        expect(connectC.isDone, isFalse);

        release.complete();
        async.flushMicrotasks();

        expect(connectC.error, isNull);
        expect(later.single.isDone, isTrue);
        expect(later.single.error, isNull);
        expect(orchestrator.activeServerId, 'A');
      });
    });
  });

  test('dispose waits for queued commands', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B'));
      final a = _context(orchestrator, 'A');
      final b = _context(orchestrator, 'B');
      final release = Completer<void>();
      gate(b, #activate, release);

      final settled = <String>[];
      _Outcome(
        orchestrator.switchActiveServer('B'),
        log: settled,
        name: 'switch to B',
      );
      _Outcome(
        orchestrator.switchActiveServer('A'),
        log: settled,
        name: 'switch to A',
      );
      _Outcome(orchestrator.dispose(), log: settled, name: 'dispose');
      async.flushMicrotasks();
      expect(settled, isEmpty);

      release.complete();
      async.flushMicrotasks();

      expect(settled, ['switch to B', 'switch to A', 'dispose']);
      verify(a.dispose).called(1);
      verify(b.dispose).called(1);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a timer expiring after dispose does nothing', () {
    _run((async, repo, orchestrator) {
      _settle(async, orchestrator.connectServer('A'));
      _settle(async, orchestrator.connectServer('B', makeActive: true));
      final a = _context(orchestrator, 'A');

      // Hold a command, so dispose is still waiting when A's timer fires.
      final release = Completer<void>();
      when(() => repo.getServer('C')).thenAnswer((_) async {
        await release.future;
        return testServerConfig(id: 'C');
      });
      final connectC = _Outcome(orchestrator.connectServer('C'));
      final disposed = _Outcome(orchestrator.dispose());
      async.elapse(_pastExpiry);
      expect(disposed.isDone, isFalse);

      release.complete();
      async.flushMicrotasks();

      expect(connectC.error, isNull);
      expect(disposed.isDone, isTrue);
      verifyNever(a.suspend);
      verifyNever(
        () => repo.updateConnectionState(
          serverId: 'A',
          newState: ConnectionState.monitoring,
        ),
      );
      verify(a.dispose).called(1);
    });
  });
}

/// Runs [body] under a fake clock against an initialized orchestrator that
/// knows servers A, B and C, then disposes it. The orchestrator is built
/// inside the fake clock so its timers and microtasks run on it.
void _run(
  void Function(
    FakeAsync async,
    MockServerRepository repo,
    ServerOrchestratorImpl orchestrator,
  )
  body,
) {
  fakeAsync((async) {
    final (:repo, :prefsRepo, :orchestrator) = stubbedOrchestrator();
    when(prefsRepo.get).thenAnswer((_) async => _kPrefs);
    for (final id in ['A', 'B', 'C']) {
      when(
        () => repo.getServer(id),
      ).thenAnswer((_) async => testServerConfig(id: id));
    }
    _settle(async, orchestrator.initialize());

    body(async, repo, orchestrator);

    _settle(async, orchestrator.dispose());
  });
}

MockServerContext _context(ServerOrchestrator orchestrator, String id) =>
    orchestrator.getContext(id)! as MockServerContext;

/// Flushes [async] and expects [future] to have completed without error.
void _settle(FakeAsync async, Future<void> future) {
  final outcome = _Outcome(future);
  async.flushMicrotasks();
  expect(outcome.isDone, isTrue, reason: 'still pending');
  expect(outcome.error, isNull);
}

/// Records how a future settles, so a test can look while it is pending.
/// With a `log`, appends `name` when it succeeds, or `'name failed: …'`.
class _Outcome {
  _Outcome(Future<void> future, {List<String>? log, String name = ''}) {
    unawaited(
      future.then<void>(
        (_) {
          isDone = true;
          log?.add(name);
        },
        onError: (Object e) {
          isDone = true;
          error = e;
          log?.add('$name failed: $e');
        },
      ),
    );
  }

  bool isDone = false;
  Object? error;
}
