import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/dto.dart';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

/// Hand-written rather than mocked: these tests need to push transitions
/// through `watch()` mid-test, and the replay-on-subscribe contract from #9
/// is load-bearing for the revalidation trigger.
class FakeConnectivityService implements ConnectivityService {
  FakeConnectivityService([this._current = ConnectivityState.online]);

  ConnectivityState _current;
  final StreamController<ConnectivityState> _controller =
      StreamController<ConnectivityState>.broadcast();

  @override
  ConnectivityState get current => _current;

  @override
  Stream<ConnectivityState> watch() => Stream.multi((controller) {
    controller.add(_current);
    final sub = _controller.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  void emit(ConnectivityState next) {
    _current = next;
    _controller.add(next);
  }

  Future<void> dispose() => _controller.close();
}

AuthResponse _session({String token = 'tok-abc'}) => AuthResponse(
  token: token,
  user: AuthUser(
    id: 'u1',
    username: 'testuser',
    email: 'u1@example.com',
    emailVerified: true,
    createdAt: DateTime(2099),
    updatedAt: DateTime(2099),
  ),
  expiresAt: DateTime(2099).toUtc(),
);

/// #98: optimistic offline session restore, bloc layer.
void main() {
  late MockAuthRepository repo;
  late FakeConnectivityService connectivity;
  late StreamController<AuthState> repoStates;

  setUp(() {
    repo = MockAuthRepository();
    connectivity = FakeConnectivityService();
    repoStates = StreamController<AuthState>.broadcast();
    when(() => repo.watchAuthState()).thenAnswer((_) => repoStates.stream);
    when(() => repo.restoreCachedSession()).thenAnswer((_) async => null);
    when(() => repo.getCachedSession()).thenAnswer((_) async => null);
    // Restore emissions read the repository's verification (#98 review);
    // Unknown exercises the unverifiedOffline fallback, matching a real
    // cold start.
    when(() => repo.currentAuthState).thenReturn(const AuthStateUnknown());
  });

  tearDown(() async {
    await connectivity.dispose();
    await repoStates.close();
  });

  AuthBloc build({
    Duration? revalidationInterval,
    Duration restoreBudget = const Duration(seconds: 4),
  }) => AuthBloc(
    authRepository: repo,
    connectivity: connectivity,
    restoreBudget: restoreBudget,
    // Default OFF in tests: the periodic retry is covered explicitly
    // below; everywhere else a live timer only adds nondeterminism.
    revalidationInterval: revalidationInterval,
  );

  group('offline shortcut and restore budget', () {
    blocTest<AuthBloc, AuthBlocState>(
      'enters on the cached session WITHOUT a network call when connectivity '
      'already reports offline',
      build: () {
        connectivity.emit(ConnectivityState.offline);
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
      ],
      verify: (_) {
        // The point of the fast path: no doomed round trip burning the full
        // Dio timeout on the splash.
        verifyNever(() => repo.getSession());
      },
    );

    blocTest<AuthBloc, AuthBlocState>(
      'still attempts the check when offline with NO cached session — a '
      'first-run user needs the sign-in form, not a retry view with nothing '
      'to retry into',
      build: () {
        connectivity.emit(ConnectivityState.offline);
        when(() => repo.restoreCachedSession()).thenAnswer((_) async => null);
        // No stored material: the repository answers from storage without a
        // network call.
        when(() => repo.getSession()).thenAnswer((_) async => null);
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        const AuthUnauthenticated(),
      ],
      verify: (_) => verify(() => repo.getSession()).called(1),
    );

    blocTest<AuthBloc, AuthBlocState>(
      'BUDGET: a check that outlives the budget enters on the cached '
      'session — the primary offline cold-start path, where the '
      'connectivity seed still lies about being online (#98 review)',
      build: () {
        // Connectivity says online (the optimistic seed at cold start).
        when(() => repo.getCachedSession()).thenAnswer((_) async => _session());
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        // The check never resolves within the test — a dead network.
        when(
          () => repo.getSession(),
        ).thenAnswer((_) => Completer<AuthResponse?>().future);
        return build(restoreBudget: const Duration(milliseconds: 20));
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      wait: const Duration(milliseconds: 100),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'NO budget without restorable material — a first-run user on a slow '
      'link must wait out the real answer, not fail it early',
      build: () {
        // Probe: nothing cached. getSession resolves after what WOULD be
        // the budget, with the definitive answer.
        when(() => repo.getSession()).thenAnswer(
          (_) => Future<AuthResponse?>.delayed(
            const Duration(milliseconds: 60),
            () => null,
          ),
        );
        return build(restoreBudget: const Duration(milliseconds: 20));
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      wait: const Duration(milliseconds: 120),
      expect: () => [
        const AuthSessionCheckInProgress(),
        const AuthUnauthenticated(),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'does NOT take the shortcut on unknown connectivity — undetermined '
      'is not absent, so the attempt is still worth making',
      build: () {
        connectivity.emit(ConnectivityState.unknown);
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        when(() => repo.getSession()).thenAnswer((_) async => _session());
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(session: _session()),
      ],
      verify: (_) => verify(() => repo.getSession()).called(1),
    );
  });

  group('indeterminate fallback', () {
    blocTest<AuthBloc, AuthBlocState>(
      'enters on the cached session when the check comes back indeterminate',
      build: () {
        when(
          () => repo.getSession(),
        ).thenThrow(const AuthNetworkException(message: 'offline'));
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'falls back to the retry view when nothing is cached — #98 narrows '
      'AuthSessionCheckFailed, it does not remove it',
      build: () {
        when(
          () => repo.getSession(),
        ).thenThrow(const AuthNetworkException(message: 'offline'));
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        const AuthSessionCheckFailed(),
      ],
      verify: (b) => expect(
        (b.state as AuthSessionCheckFailed).cause,
        isA<AuthNetworkException>(),
      ),
    );

    blocTest<AuthBloc, AuthBlocState>(
      'an unexpected non-auth fault also tries the cached session',
      build: () {
        when(() => repo.getSession()).thenThrow(StateError('locked keychain'));
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'a failing restore preserves the ORIGINAL cause — a storage hiccup '
      'must not be substituted for the real network diagnosis',
      build: () {
        when(
          () => repo.getSession(),
        ).thenThrow(const AuthNetworkException(message: 'offline'));
        when(
          () => repo.restoreCachedSession(),
        ).thenThrow(StateError('keychain unavailable'));
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        const AuthSessionCheckFailed(),
      ],
      verify: (b) => expect(
        (b.state as AuthSessionCheckFailed).cause,
        isA<AuthNetworkException>(),
      ),
    );

    blocTest<AuthBloc, AuthBlocState>(
      'a definitive rejection does NOT consult the cached session — the '
      'session is gone, and entering on stale material would contradict '
      'the server',
      build: () {
        when(() => repo.getSession()).thenAnswer((_) async => null);
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        const AuthUnauthenticated(),
      ],
      verify: (_) => verifyNever(() => repo.restoreCachedSession()),
    );
  });

  group('revalidation on reconnect', () {
    blocTest<AuthBloc, AuthBlocState>(
      'clears the unverified marker when connectivity returns and the '
      'server confirms the session',
      build: () {
        connectivity.emit(ConnectivityState.offline);
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        when(() => repo.getSession()).thenAnswer((_) async => _session());
        return build();
      },
      act: (b) async {
        b.add(const AuthSessionCheckRequested());
        await Future<void>.delayed(Duration.zero);
        connectivity.emit(ConnectivityState.online);
      },
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
        // The transition the widened equality exists to expose: same
        // session, verification only.
        AuthAuthenticated(session: _session()),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'signs the user out when revalidation finds the session gone',
      build: () {
        connectivity.emit(ConnectivityState.offline);
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        when(() => repo.getSession()).thenAnswer((_) async => null);
        return build();
      },
      act: (b) async {
        b.add(const AuthSessionCheckRequested());
        await Future<void>.delayed(Duration.zero);
        connectivity.emit(ConnectivityState.online);
      },
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
        const AuthUnauthenticated(),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'keeps the optimistic session when the server is still unreachable — '
      'nothing about the user situation changed, so no transition',
      build: () {
        connectivity.emit(ConnectivityState.offline);
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        when(
          () => repo.getSession(),
        ).thenThrow(const AuthNetworkException(message: 'still offline'));
        return build();
      },
      act: (b) async {
        b.add(const AuthSessionCheckRequested());
        await Future<void>.delayed(Duration.zero);
        connectivity.emit(ConnectivityState.online);
      },
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'is a no-op for an already-verified session — reconnect events must '
      'not re-check a session the server already confirmed',
      build: () {
        when(() => repo.getSession()).thenAnswer((_) async => _session());
        return build();
      },
      act: (b) async {
        b.add(const AuthSessionCheckRequested());
        await Future<void>.delayed(Duration.zero);
        connectivity.emit(ConnectivityState.online);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(session: _session()),
      ],
      verify: (_) => verify(() => repo.getSession()).called(1),
    );

    blocTest<AuthBloc, AuthBlocState>(
      'the replayed connectivity state at construction does not trigger a '
      'check — the handler no-ops from AuthInitial',
      build: build,
      act: (b) async => Future<void>.delayed(Duration.zero),
      expect: () => const <AuthBlocState>[],
      verify: (_) => verifyNever(() => repo.getSession()),
    );

    blocTest<AuthBloc, AuthBlocState>(
      'going offline does not trigger revalidation',
      build: () {
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        when(() => repo.getSession()).thenAnswer((_) async => _session());
        return build();
      },
      act: (b) async {
        b.add(const AuthSessionCheckRequested());
        await Future<void>.delayed(Duration.zero);
        connectivity.emit(ConnectivityState.offline);
        await Future<void>.delayed(Duration.zero);
      },
      verify: (_) => verify(() => repo.getSession()).called(1),
    );
  });

  group('repository state mirror', () {
    blocTest<AuthBloc, AuthBlocState>(
      'propagates an unverifiedOffline → verified change on the SAME '
      'session; the old type-only guard swallowed it and the banner would '
      'never have cleared',
      build: build,
      seed: () => AuthAuthenticated(
        session: _session(),
        verification: SessionVerification.unverifiedOffline,
      ),
      act: (b) async {
        repoStates.add(AuthStateAuthenticated(session: _session()));
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [AuthAuthenticated(session: _session())],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'does not re-emit for an identical repository state',
      build: build,
      seed: () => AuthAuthenticated(session: _session()),
      act: (b) async {
        repoStates.add(AuthStateAuthenticated(session: _session()));
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => const <AuthBlocState>[],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'still refuses to override an in-flight startup check (#37)',
      build: () {
        when(() => repo.getSession()).thenAnswer((_) async {
          repoStates.add(const AuthStateUnauthenticated());
          await Future<void>.delayed(Duration.zero);
          return _session();
        });
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      // The stub suspends on a zero-duration TIMER after seeding the mirror
      // event. With a synchronous act and no wait, bloc_test's own close
      // timer is scheduled FIRST, so close lands mid-handler; droppable()
      // lets the in-flight handler finish but cancels its emitter, and the
      // final Authenticated emit is dropped silently — the test then fails
      // as "one state short" with no error. Holding the test open past the
      // stub's timer removes the harness race without changing what is
      // asserted: the mirror's Unauthenticated must NOT appear (the
      // in-flight guard), and the check's own terminal emit must.
      wait: const Duration(milliseconds: 20),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(session: _session()),
      ],
    );
  });

  group('periodic revalidation while unverified (#98 review)', () {
    blocTest<AuthBloc, AuthBlocState>(
      'an unverified session entered while ONLINE (5xx) is revalidated on '
      'a timer — no connectivity edge will ever fire for it',
      build: () {
        var calls = 0;
        when(() => repo.getSession()).thenAnswer((_) async {
          calls += 1;
          // First call: the startup check fails indeterminately while
          // online. Later calls: the server has recovered.
          if (calls == 1) {
            throw const AuthServerException(message: '503', statusCode: 503);
          }
          return _session();
        });
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        return build(revalidationInterval: const Duration(milliseconds: 20));
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      wait: const Duration(milliseconds: 120),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
        AuthAuthenticated(session: _session()),
      ],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'the timer stops once verified — no retry GETs for a session the '
      'server already confirmed',
      build: () {
        var calls = 0;
        when(() => repo.getSession()).thenAnswer((_) async {
          calls += 1;
          if (calls == 1) {
            throw const AuthNetworkException(message: 'offline');
          }
          return _session();
        });
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        return build(revalidationInterval: const Duration(milliseconds: 15));
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      wait: const Duration(milliseconds: 150),
      verify: (_) {
        // Startup check + exactly one revalidation; the timer must not
        // keep polling a verified session for the rest of the wait.
        verify(() => repo.getSession()).called(2);
      },
    );
  });

  group('verification comes from the repository (#98 review)', () {
    blocTest<AuthBloc, AuthBlocState>(
      'a restore that returns an already-VERIFIED session is emitted '
      'verified — a same-server bloc rebuild must not raise the banner '
      'with nothing to ever clear it',
      build: () {
        connectivity.emit(ConnectivityState.offline);
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        // The repository never downgrades: it still holds the session as
        // verified and reports so.
        when(
          () => repo.currentAuthState,
        ).thenReturn(AuthStateAuthenticated(session: _session()));
        return build();
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(session: _session()),
      ],
    );
  });

  group('without a connectivity service', () {
    blocTest<AuthBloc, AuthBlocState>(
      'the indeterminate fallback still works; only the fast path and '
      'automatic revalidation are absent',
      build: () {
        when(
          () => repo.getSession(),
        ).thenThrow(const AuthNetworkException(message: 'offline'));
        when(
          () => repo.restoreCachedSession(),
        ).thenAnswer((_) async => _session());
        return AuthBloc(authRepository: repo);
      },
      act: (b) => b.add(const AuthSessionCheckRequested()),
      expect: () => [
        const AuthSessionCheckInProgress(),
        AuthAuthenticated(
          session: _session(),
          verification: SessionVerification.unverifiedOffline,
        ),
      ],
    );
  });
}
