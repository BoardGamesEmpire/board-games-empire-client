import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';

import '../support/auth_test_fixtures.dart';

/// Pins how sign-in and register map each [AuthException] to a state (#880).
///
/// The two handlers share most of their failure arms, but each words two
/// failures of its own and sends the other's two to [AuthFailureServer]. A
/// test per handler and exception keeps any refactor of the shared arms from
/// moving either.
void main() {
  late MockAuthRepository mockRepo;

  setUp(() {
    mockRepo = MockAuthRepository();
    when(
      () => mockRepo.watchAuthState(),
    ).thenAnswer((_) => const Stream.empty());
    when(() => mockRepo.restoreCachedSession()).thenAnswer((_) async => null);
    when(() => mockRepo.getCachedSession()).thenAnswer((_) async => null);
  });

  // Each failure's cause is left out of state equality, so the states that
  // carry one are matched on the very exception thrown.
  Matcher serverFailure(AuthException e) => isA<AuthFailureServer>().having(
    (s) => s.cause,
    'cause',
    same(e),
  );
  Matcher localDecodeFailure(AuthException e) =>
      isA<AuthFailureLocalDecode>().having((s) => s.cause, 'cause', same(e));

  const superseded = AuthSupersededException();
  const invalidCredentials = AuthInvalidCredentialsException();
  const emailNotVerified = AuthEmailNotVerifiedException();
  const registrationDisabled = AuthRegistrationDisabledException();
  const emailAlreadyExists = AuthEmailAlreadyExistsException();
  const sessionNotGranted = AuthSessionNotGrantedException();
  const localDecode = AuthLocalDecodeException(message: 'x');
  const network = AuthNetworkException(message: 'x');
  const rateLimited = AuthRateLimitedException(
    retryAfter: Duration(seconds: 7),
  );
  const server = AuthServerException(message: 'x');

  // No sign-out of this bloc's is in flight, so the mirror names the session
  // lost. The cause is spelled out because it is what the row pins.
  // ignore: avoid_redundant_argument_values
  const sessionLost = AuthUnauthenticated(cause: SignOutCause.sessionLost);

  // The thrown exception, and what each handler emits after AuthLoading.
  final rows = <(AuthException, Object, Object)>[
    (superseded, sessionLost, sessionLost),
    (
      invalidCredentials,
      const AuthFailureInvalidCredentials(),
      serverFailure(invalidCredentials),
    ),
    (
      emailNotVerified,
      const AuthFailureEmailNotVerified(),
      serverFailure(emailNotVerified),
    ),
    (
      registrationDisabled,
      serverFailure(registrationDisabled),
      const AuthFailureRegistrationDisabled(),
    ),
    (
      emailAlreadyExists,
      serverFailure(emailAlreadyExists),
      const AuthFailureEmailAlreadyExists(),
    ),
    (
      sessionNotGranted,
      const AuthFailureSessionNotGranted(),
      const AuthFailureSessionNotGranted(),
    ),
    (
      localDecode,
      localDecodeFailure(localDecode),
      localDecodeFailure(localDecode),
    ),
    (network, const AuthFailureNetwork(), const AuthFailureNetwork()),
    (
      rateLimited,
      const AuthFailureRateLimited(Duration(seconds: 7)),
      const AuthFailureRateLimited(Duration(seconds: 7)),
    ),
    (server, serverFailure(server), serverFailure(server)),
  ];

  for (final (thrown, onSignIn, onRegister) in rows) {
    final name = thrown.runtimeType;

    blocTest<AuthBloc, AuthBlocState>(
      'maps $name on sign-in as before',
      build: () {
        when(
          () => mockRepo.signIn(
            email: any(named: 'email'),
            password: any(named: 'password'),
          ),
        ).thenThrow(thrown);
        return AuthBloc(authRepository: mockRepo);
      },
      seed: () => const AuthUnauthenticated(),
      act: (bloc) => bloc.add(
        const AuthSignInRequested(email: 'a@b.com', password: 'p'),
      ),
      expect: () => [const AuthLoading(), onSignIn],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'maps $name on register as before',
      build: () {
        when(
          () => mockRepo.signUp(
            email: any(named: 'email'),
            password: any(named: 'password'),
            username: any(named: 'username'),
            firstName: any(named: 'firstName'),
            lastName: any(named: 'lastName'),
          ),
        ).thenThrow(thrown);
        return AuthBloc(authRepository: mockRepo);
      },
      seed: () => const AuthUnauthenticated(),
      act: (bloc) => bloc.add(
        const AuthRegisterRequested(
          email: 'a@b.com',
          password: 'p',
          username: 'u',
        ),
      ),
      expect: () => [const AuthLoading(), onRegister],
    );
  }
}
