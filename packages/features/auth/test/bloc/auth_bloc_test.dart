import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/dto.dart';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

AuthResponse _session() => AuthResponse(
  token: 'tok-abc',
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

void main() {
  late MockAuthRepository mockRepo;

  setUp(() {
    mockRepo = MockAuthRepository();
    when(
      () => mockRepo.watchAuthState(),
    ).thenAnswer((_) => const Stream.empty());
  });

  group('AuthBloc', () {
    group('AuthSessionCheckRequested', () {
      blocTest<AuthBloc, AuthBlocState>(
        'emits [session check in progress, authenticated] when session '
        'exists',
        build: () {
          when(() => mockRepo.getSession()).thenAnswer((_) async => _session());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [
          const AuthSessionCheckInProgress(),
          isA<AuthAuthenticated>(),
        ],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits [session check in progress, unauthenticated] when no session',
        build: () {
          when(() => mockRepo.getSession()).thenAnswer((_) async => null);
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [
          const AuthSessionCheckInProgress(),
          const AuthUnauthenticated(),
        ],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits [session check in progress, session check failed] on a '
        'network error — indeterminate, never the sign-in form (#37)',
        build: () {
          when(
            () => mockRepo.getSession(),
          ).thenThrow(const AuthNetworkException(message: 'offline'));
          return AuthBloc(authRepository: mockRepo);
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
        'emits [session check in progress, session check failed] on a '
        'server error — a 5xx cannot verify the session either',
        build: () {
          when(() => mockRepo.getSession()).thenThrow(
            const AuthServerException(
              message: 'Server error 503.',
              statusCode: 503,
            ),
          );
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [
          const AuthSessionCheckInProgress(),
          const AuthSessionCheckFailed(),
        ],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits [session check in progress, unauthenticated] on a rejected '
        'session (403 → invalid-credentials) — gone, not indeterminate; '
        'goes to the form, never the retry view (#37 review)',
        build: () {
          when(
            () => mockRepo.getSession(),
          ).thenThrow(const AuthInvalidCredentialsException());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [
          const AuthSessionCheckInProgress(),
          const AuthUnauthenticated(),
        ],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits [session check in progress, session check failed] on an '
        'unexpected non-auth fault (e.g. locked keychain) — indeterminate, '
        'never an endless splash (#37 review)',
        build: () {
          when(
            () => mockRepo.getSession(),
          ).thenThrow(StateError('keychain locked'));
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [
          const AuthSessionCheckInProgress(),
          const AuthSessionCheckFailed(),
        ],
        verify: (b) => expect(
          (b.state as AuthSessionCheckFailed).cause,
          isA<StateError>(),
        ),
      );

      blocTest<AuthBloc, AuthBlocState>(
        'drops a second concurrent session check while the first is in '
        'flight (droppable) — no overlapping getSession (#37 review)',
        build: () {
          var calls = 0;
          when(() => mockRepo.getSession()).thenAnswer((_) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return calls == 1 ? _session() : null;
          });
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) {
          b.add(const AuthSessionCheckRequested());
          b.add(const AuthSessionCheckRequested());
        },
        wait: const Duration(milliseconds: 60),
        expect: () => [
          const AuthSessionCheckInProgress(),
          isA<AuthAuthenticated>(),
        ],
        verify: (_) => verify(() => mockRepo.getSession()).called(1),
      );
    });

    group('AuthSignInRequested', () {
      blocTest<AuthBloc, AuthBlocState>(
        'emits [loading, authenticated] on success',
        build: () {
          when(
            () => mockRepo.signIn(
              email: any(named: 'email'),
              password: any(named: 'password'),
            ),
          ).thenAnswer((_) async => _session());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(
          const AuthSignInRequested(email: 'a@b.com', password: 'pass'),
        ),
        expect: () => [const AuthLoading(), isA<AuthAuthenticated>()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits the invalid-credentials kind on rejection — no display '
        'strings in the bloc (#37 i18n)',
        build: () {
          when(
            () => mockRepo.signIn(
              email: any(named: 'email'),
              password: any(named: 'password'),
            ),
          ).thenThrow(const AuthInvalidCredentialsException());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(
          const AuthSignInRequested(email: 'a@b.com', password: 'wrong'),
        ),
        expect: () => [
          const AuthLoading(),
          const AuthFailureInvalidCredentials(),
        ],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits the network kind on a connectivity failure',
        build: () {
          when(
            () => mockRepo.signIn(
              email: any(named: 'email'),
              password: any(named: 'password'),
            ),
          ).thenThrow(const AuthNetworkException(message: 'timeout'));
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) =>
            b.add(const AuthSignInRequested(email: 'a@b.com', password: 'p')),
        expect: () => [const AuthLoading(), const AuthFailureNetwork()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits the server kind (cause retained) on an unexpected failure',
        build: () {
          when(
            () => mockRepo.signIn(
              email: any(named: 'email'),
              password: any(named: 'password'),
            ),
          ).thenThrow(
            const AuthServerException(message: 'boom', statusCode: 500),
          );
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) =>
            b.add(const AuthSignInRequested(email: 'a@b.com', password: 'p')),
        expect: () => [const AuthLoading(), const AuthFailureServer()],
        verify: (b) => expect(
          (b.state as AuthFailureServer).cause,
          isA<AuthServerException>(),
        ),
      );
    });

    group('AuthRegisterRequested', () {
      blocTest<AuthBloc, AuthBlocState>(
        'emits [loading, authenticated] on success',
        build: () {
          when(
            () => mockRepo.signUp(
              email: any(named: 'email'),
              password: any(named: 'password'),
              username: any(named: 'username'),
              firstName: any(named: 'firstName'),
              lastName: any(named: 'lastName'),
            ),
          ).thenAnswer((_) async => _session());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(
          const AuthRegisterRequested(
            email: 'new@b.com',
            password: 'pass',
            username: 'newuser',
          ),
        ),
        expect: () => [const AuthLoading(), isA<AuthAuthenticated>()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits the email-exists kind on duplicate email — the kind implies '
        'the email field, no stringly-typed field name (#37 i18n)',
        build: () {
          when(
            () => mockRepo.signUp(
              email: any(named: 'email'),
              password: any(named: 'password'),
              username: any(named: 'username'),
              firstName: any(named: 'firstName'),
              lastName: any(named: 'lastName'),
            ),
          ).thenThrow(const AuthEmailAlreadyExistsException());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(
          const AuthRegisterRequested(
            email: 'dup@b.com',
            password: 'p',
            username: 'u',
          ),
        ),
        expect: () => [
          const AuthLoading(),
          const AuthFailureEmailAlreadyExists(),
        ],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits the registration-disabled kind when the server disables '
        'sign-up',
        build: () {
          when(
            () => mockRepo.signUp(
              email: any(named: 'email'),
              password: any(named: 'password'),
              username: any(named: 'username'),
              firstName: any(named: 'firstName'),
              lastName: any(named: 'lastName'),
            ),
          ).thenThrow(const AuthRegistrationDisabledException());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(
          const AuthRegisterRequested(
            email: 'a@b.com',
            password: 'p',
            username: 'u',
          ),
        ),
        expect: () => [
          const AuthLoading(),
          const AuthFailureRegistrationDisabled(),
        ],
      );
    });

    group('AuthSignOutRequested', () {
      blocTest<AuthBloc, AuthBlocState>(
        'emits [loading, unauthenticated]',
        build: () {
          when(() => mockRepo.signOut()).thenAnswer((_) async {});
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSignOutRequested()),
        expect: () => [const AuthLoading(), const AuthUnauthenticated()],
        verify: (_) => verify(() => mockRepo.signOut()).called(1),
      );

      blocTest<AuthBloc, AuthBlocState>(
        'still emits [loading, unauthenticated] on '
        'AuthSignOutPersistenceException — the repo has already '
        'transitioned to unauthenticated per contract; the error is '
        'surfaced via addError, not swallowed (#37)',
        build: () {
          when(() => mockRepo.signOut()).thenThrow(
            const AuthSignOutPersistenceException(
              cause: 'secure storage clear failed',
            ),
          );
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSignOutRequested()),
        expect: () => [const AuthLoading(), const AuthUnauthenticated()],
        errors: () => [isA<AuthSignOutPersistenceException>()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'a non-AuthException from signOut still flips to unauthenticated — '
        'sign-out is intent-to-leave, so the gate must flip regardless; '
        'the error is surfaced via addError (#37 review)',
        build: () {
          when(
            () => mockRepo.signOut(),
          ).thenThrow(StateError('unexpected in signOut path'));
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSignOutRequested()),
        expect: () => [const AuthLoading(), const AuthUnauthenticated()],
        errors: () => [isA<StateError>()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'no resurrection: a failed persisted clear followed by the '
        "repository's (fixed-contract) unauthenticated mirror emission "
        'lands and STAYS on unauthenticated — never authenticated '
        '(#37 review regression)',
        build: () {
          final repoStates = Stream<AuthState>.fromIterable(const [
            AuthStateUnauthenticated(),
          ]);
          when(() => mockRepo.watchAuthState()).thenAnswer((_) => repoStates);
          when(() => mockRepo.signOut()).thenThrow(
            const AuthSignOutPersistenceException(
              cause: 'secure storage clear failed',
            ),
          );
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) async {
          b.add(const AuthSignOutRequested());
          // Let the sign-out handler and the mirrored repo emission both
          // settle, in whichever order they interleave.
          await Future<void>.delayed(Duration.zero);
        },
        expect: () => isNot(contains(isA<AuthAuthenticated>())),
        errors: () => [isA<AuthSignOutPersistenceException>()],
        verify: (b) => expect(b.state, const AuthUnauthenticated()),
      );
    });

    group('repository state mirroring', () {
      blocTest<AuthBloc, AuthBlocState>(
        'reflects unauthenticated from repo stream',
        build: () {
          when(
            () => mockRepo.watchAuthState(),
          ).thenAnswer((_) => Stream.value(const AuthStateUnauthenticated()));
          return AuthBloc(authRepository: mockRepo);
        },
        expect: () => [const AuthUnauthenticated()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'does not clobber an in-flight session check — a stray repo '
        'Unauthenticated during the check is ignored; the check owns the '
        'terminal emit (#37 review, indeterminate-never-shows-form)',
        build: () {
          when(() => mockRepo.getSession()).thenAnswer((_) async {
            // While the check is in flight, the repo mirrors an
            // Unauthenticated (e.g. an interceptor 401 on another request).
            await Future<void>.delayed(const Duration(milliseconds: 10));
            throw const AuthNetworkException(message: 'offline');
          });
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) {
          b.add(const AuthSessionCheckRequested());
          b.add(const AuthRepositoryStateChanged(AuthStateUnauthenticated()));
        },
        wait: const Duration(milliseconds: 30),
        expect: () => [
          const AuthSessionCheckInProgress(),
          const AuthSessionCheckFailed(),
        ],
      );
    });
  });
}
