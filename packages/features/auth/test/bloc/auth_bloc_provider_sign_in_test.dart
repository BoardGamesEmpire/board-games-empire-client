import 'dart:async';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/dto.dart' show AuthResponse;

import '../support/auth_test_fixtures.dart';

void main() {
  late MockAuthRepository repo;

  setUpAll(() => registerFallbackValue(kOidcStrategy));

  setUp(() {
    repo = MockAuthRepository();
    when(() => repo.watchAuthState()).thenAnswer((_) => const Stream.empty());
    when(() => repo.restoreCachedSession()).thenAnswer((_) async => null);
    when(() => repo.getCachedSession()).thenAnswer((_) async => null);
  });

  const loading = AuthLoading(providerId: 'authentik');

  blocTest<AuthBloc, AuthBlocState>(
    'a completed provider sign-in: '
    '[AuthLoading(providerId), AuthAuthenticated]',
    build: () {
      when(() => repo.signInWithProvider(any()))
          .thenAnswer((_) async => ProviderSignInCompleted(testSession()));
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [loading, AuthAuthenticated(session: testSession())],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'a cancelled one returns to AuthUnauthenticated with no failure',
    build: () {
      when(() => repo.signInWithProvider(any()))
          .thenAnswer((_) async => const ProviderSignInCancelled());
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [loading, const AuthUnauthenticated()],
  );

  // A web page that leaves for the provider never sees the call complete.
  blocTest<AuthBloc, AuthBlocState>(
    'while the call is pending, only the loading state is emitted',
    build: () {
      when(() => repo.signInWithProvider(any()))
          .thenAnswer((_) => Completer<ProviderSignInOutcome>().future);
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [loading],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'a refusal emits AuthFailureProviderSignIn with its reason',
    build: () {
      when(() => repo.signInWithProvider(any())).thenThrow(
        const AuthProviderSignInException(
          ProviderSignInFailureReason.registrationDisabled,
          code: 'REGISTRATION_DISABLED',
        ),
      );
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [
      loading,
      const AuthFailureProviderSignIn(
        ProviderSignInFailureReason.registrationDisabled,
      ),
    ],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'a rate limit carries its wait',
    build: () {
      when(() => repo.signInWithProvider(any())).thenThrow(
        const AuthRateLimitedException(retryAfter: Duration(seconds: 7)),
      );
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [
      loading,
      const AuthFailureProviderSignIn(
        ProviderSignInFailureReason.rateLimited,
        retryAfter: Duration(seconds: 7),
      ),
    ],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'a network failure gives reason network',
    build: () {
      when(() => repo.signInWithProvider(any()))
          .thenThrow(const AuthNetworkException(message: 'offline'));
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [
      loading,
      const AuthFailureProviderSignIn(ProviderSignInFailureReason.network),
    ],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'an AuthServerException gives reason generic',
    build: () {
      when(() => repo.signInWithProvider(any()))
          .thenThrow(const AuthServerException(message: 'boom'));
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [
      loading,
      const AuthFailureProviderSignIn(ProviderSignInFailureReason.generic),
    ],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'a superseded attempt lands quietly',
    build: () {
      when(() => repo.signInWithProvider(any()))
          .thenThrow(const AuthSupersededException());
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthProviderSignInRequested(kOidcStrategy)),
    expect: () => [loading, const AuthUnauthenticated()],
  );

  // On web, another tab's sign-in reaches this bloc through the repository
  // while the attempt is still settling: during its start request, or the
  // grace after a page that did not leave. The attempt's own ending must not
  // throw that live session back to the sign-in screen.
  group('a session that lands while the attempt is pending is kept when the '
      'attempt', () {
    final endings = <String, void Function(Completer<ProviderSignInOutcome>)>{
      'is cancelled': (gate) => gate.complete(const ProviderSignInCancelled()),
      'is superseded': (gate) =>
          gate.completeError(const AuthSupersededException()),
      'is refused': (gate) => gate.completeError(
        const AuthProviderSignInException(ProviderSignInFailureReason.generic),
      ),
      'fails on the network': (gate) =>
          gate.completeError(const AuthNetworkException(message: 'offline')),
    };

    for (final MapEntry(key: name, value: end) in endings.entries) {
      late StreamController<AuthState> repoStates;
      late Completer<ProviderSignInOutcome> gate;

      blocTest<AuthBloc, AuthBlocState>(
        name,
        build: () {
          repoStates = StreamController<AuthState>();
          addTearDown(repoStates.close);
          gate = Completer<ProviderSignInOutcome>();
          when(() => repo.watchAuthState())
              .thenAnswer((_) => repoStates.stream);
          when(() => repo.signInWithProvider(any()))
              .thenAnswer((_) => gate.future);
          return AuthBloc(authRepository: repo);
        },
        act: (b) async {
          b.add(const AuthProviderSignInRequested(kOidcStrategy));
          await pumpEventQueue();
          repoStates.add(AuthStateAuthenticated(session: testSession()));
          await pumpEventQueue();
          end(gate);
        },
        expect: () => [loading, AuthAuthenticated(session: testSession())],
      );
    }
  });

  // On web the page regaining focus re-reads the session, and a read that
  // finds none publishes unauthenticated again though nothing changed. The
  // grant still pending owns what the screen shows: dropping its loading
  // state would show buttons that look live while every press is dropped.
  group('a no-session reading while a grant is pending keeps it loading', () {
    late StreamController<AuthState> repoStates;

    setUp(() {
      repoStates = StreamController<AuthState>();
      addTearDown(repoStates.close);
      when(() => repo.watchAuthState()).thenAnswer((_) => repoStates.stream);
    });

    blocTest<AuthBloc, AuthBlocState>(
      'a provider attempt, which then settles the screen itself',
      build: () {
        final gate = Completer<ProviderSignInOutcome>();
        when(() => repo.signInWithProvider(any()))
            .thenAnswer((_) => gate.future);
        addTearDown(() {
          if (!gate.isCompleted) gate.complete(const ProviderSignInCancelled());
        });
        return AuthBloc(authRepository: repo);
      },
      act: (b) async {
        b.add(const AuthProviderSignInRequested(kOidcStrategy));
        await pumpEventQueue();
        repoStates.add(const AuthStateUnauthenticated());
        await pumpEventQueue();
      },
      expect: () => [loading],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'a password sign-in',
      build: () {
        final gate = Completer<AuthResponse>();
        when(
          () => repo.signIn(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenAnswer((_) => gate.future);
        addTearDown(() {
          if (!gate.isCompleted) gate.complete(testSession());
        });
        return AuthBloc(authRepository: repo);
      },
      act: (b) async {
        b.add(const AuthSignInRequested(email: 'a@b.c', password: 'pw'));
        await pumpEventQueue();
        repoStates.add(const AuthStateUnauthenticated());
        await pumpEventQueue();
      },
      expect: () => [const AuthLoading()],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'but once the grant has settled the mirror follows again',
      build: () {
        when(() => repo.signInWithProvider(any()))
            .thenAnswer((_) async => ProviderSignInCompleted(testSession()));
        return AuthBloc(authRepository: repo);
      },
      act: (b) async {
        b.add(const AuthProviderSignInRequested(kOidcStrategy));
        await pumpEventQueue();
        repoStates.add(const AuthStateUnauthenticated());
        await pumpEventQueue();
      },
      expect: () => [
        loading,
        AuthAuthenticated(session: testSession()),
        const AuthUnauthenticated(),
      ],
    );
  });

  blocTest<AuthBloc, AuthBlocState>(
    'a second request while one is in flight is dropped',
    build: () {
      final gate = Completer<ProviderSignInOutcome>();
      when(() => repo.signInWithProvider(any())).thenAnswer((_) => gate.future);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(const ProviderSignInCancelled());
      });
      return AuthBloc(authRepository: repo);
    },
    act: (b) {
      b
        ..add(const AuthProviderSignInRequested(kOidcStrategy))
        ..add(const AuthProviderSignInRequested(kOidcStrategy));
    },
    expect: () => [loading],
    verify: (_) => verify(() => repo.signInWithProvider(any())).called(1),
  );

  group('one credential grant at a time, across the three kinds', () {
    blocTest<AuthBloc, AuthBlocState>(
      'a provider request while a password sign-in is in flight is dropped: '
      'no browser opens, and the sign-in settles the screen',
      build: () {
        final gate = Completer<AuthResponse>();
        when(
          () => repo.signIn(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenAnswer((_) => gate.future);
        addTearDown(() {
          if (!gate.isCompleted) gate.complete(testSession());
        });
        return AuthBloc(authRepository: repo);
      },
      act: (b) async {
        b
          ..add(const AuthSignInRequested(email: 'a@b.c', password: 'pw'))
          ..add(const AuthProviderSignInRequested(kOidcStrategy));
        await pumpEventQueue();
      },
      expect: () => [const AuthLoading()],
      verify: (_) => verifyNever(() => repo.signInWithProvider(any())),
    );

    blocTest<AuthBloc, AuthBlocState>(
      'a password sign-in or a registration while a provider sign-in is in '
      'flight is dropped',
      build: () {
        final gate = Completer<ProviderSignInOutcome>();
        when(() => repo.signInWithProvider(any()))
            .thenAnswer((_) => gate.future);
        addTearDown(() {
          if (!gate.isCompleted) gate.complete(const ProviderSignInCancelled());
        });
        return AuthBloc(authRepository: repo);
      },
      act: (b) async {
        b
          ..add(const AuthProviderSignInRequested(kOidcStrategy))
          ..add(const AuthSignInRequested(email: 'a@b.c', password: 'pw'))
          ..add(
            const AuthRegisterRequested(
              email: 'a@b.c',
              password: 'pw',
              username: 'u',
            ),
          );
        await pumpEventQueue();
      },
      expect: () => [loading],
      verify: (_) {
        verifyNever(
          () => repo.signIn(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        );
        verifyNever(
          () => repo.signUp(
            email: any(named: 'email'),
            password: any(named: 'password'),
            username: any(named: 'username'),
            firstName: any(named: 'firstName'),
            lastName: any(named: 'lastName'),
          ),
        );
      },
    );

    blocTest<AuthBloc, AuthBlocState>(
      'once a grant settles, the next one runs',
      build: () {
        when(() => repo.signInWithProvider(any()))
            .thenAnswer((_) async => const ProviderSignInCancelled());
        when(
          () => repo.signIn(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenAnswer((_) async => testSession());
        return AuthBloc(authRepository: repo);
      },
      act: (b) async {
        b.add(const AuthProviderSignInRequested(kOidcStrategy));
        await pumpEventQueue();
        b.add(const AuthSignInRequested(email: 'a@b.c', password: 'pw'));
      },
      expect: () => [
        loading,
        const AuthUnauthenticated(),
        const AuthLoading(),
        AuthAuthenticated(session: testSession()),
      ],
    );
  });

  blocTest<AuthBloc, AuthBlocState>(
    'a startup session check with a pending failed return emits the provider '
    'failure, not sessionLost',
    build: () {
      when(() => repo.getSession()).thenAnswer((_) async => null);
      when(() => repo.takeProviderSignInReturn()).thenReturn(
        const AuthProviderSignInException(
          ProviderSignInFailureReason.accessDenied,
        ),
      );
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthSessionCheckRequested()),
    expect: () => [
      const AuthSessionCheckInProgress(),
      const AuthFailureProviderSignIn(ProviderSignInFailureReason.accessDenied),
    ],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'a startup session check without one emits '
    'AuthUnauthenticated(sessionLost)',
    build: () {
      when(() => repo.getSession()).thenAnswer((_) async => null);
      when(() => repo.takeProviderSignInReturn()).thenReturn(null);
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthSessionCheckRequested()),
    expect: () => [
      const AuthSessionCheckInProgress(),
      // Pins the cause itself, not whatever the default is.
      // ignore: avoid_redundant_argument_values
      const AuthUnauthenticated(cause: SignOutCause.sessionLost),
    ],
  );

  blocTest<AuthBloc, AuthBlocState>(
    'AuthFailureCleared retires a provider failure',
    build: () => AuthBloc(authRepository: repo),
    seed: () =>
        const AuthFailureProviderSignIn(ProviderSignInFailureReason.generic),
    act: (b) => b.add(const AuthFailureCleared()),
    expect: () => [const AuthUnauthenticated()],
  );

  test('providerSignInAvailability forwards the repository', () {
    when(() => repo.providerSignInAvailability)
        .thenReturn(const ProviderSignInUnsupportedDevice());
    final bloc = AuthBloc(authRepository: repo);
    addTearDown(bloc.close);
    expect(
      bloc.providerSignInAvailability,
      isA<ProviderSignInUnsupportedDevice>(),
    );
  });
}
