import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

AuthResponse _session() => AuthResponse(
  token: 'tok-abc',
  user: User(id: 'u1', username: 'testuser'),
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
        'emits [loading, authenticated] when session exists',
        build: () {
          when(() => mockRepo.getSession()).thenAnswer((_) async => _session());
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [const AuthLoading(), isA<AuthAuthenticated>()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits [loading, unauthenticated] when no session',
        build: () {
          when(() => mockRepo.getSession()).thenAnswer((_) async => null);
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [const AuthLoading(), const AuthUnauthenticated()],
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits [loading, failure] on network error',
        build: () {
          when(
            () => mockRepo.getSession(),
          ).thenThrow(const AuthNetworkException(message: 'offline'));
          return AuthBloc(authRepository: mockRepo);
        },
        act: (b) => b.add(const AuthSessionCheckRequested()),
        expect: () => [const AuthLoading(), isA<AuthFailure>()],
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
        'emits failure on invalid credentials',
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
        expect: () => [const AuthLoading(), isA<AuthFailure>()],
        verify: (b) =>
            expect((b.state as AuthFailure).message, contains('Incorrect')),
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits failure on network error',
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
        expect: () => [const AuthLoading(), isA<AuthFailure>()],
        verify: (b) =>
            expect((b.state as AuthFailure).message, contains('server')),
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
        'emits failure with email field on duplicate email',
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
        verify: (b) => expect((b.state as AuthFailure).field, 'email'),
      );

      blocTest<AuthBloc, AuthBlocState>(
        'emits failure when registration disabled',
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
        expect: () => [const AuthLoading(), isA<AuthFailure>()],
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
    });
  });
}
