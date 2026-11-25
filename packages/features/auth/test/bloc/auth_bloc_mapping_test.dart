import 'dart:async';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/dto.dart' show AuthResponse;

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
  Matcher serverFailure(Object e) => isA<AuthFailureServer>().having(
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

  void stubSignIn(Future<AuthResponse> Function() answer) => when(
    () => mockRepo.signIn(
      email: any(named: 'email'),
      password: any(named: 'password'),
    ),
  ).thenAnswer((_) => answer());

  void stubSignUp(Future<AuthResponse> Function() answer) => when(
    () => mockRepo.signUp(
      email: any(named: 'email'),
      password: any(named: 'password'),
      username: any(named: 'username'),
      firstName: any(named: 'firstName'),
      lastName: any(named: 'lastName'),
    ),
  ).thenAnswer((_) => answer());

  const signIn = AuthSignInRequested(email: 'a@b.com', password: 'p');
  const register = AuthRegisterRequested(
    email: 'a@b.com',
    password: 'p',
    username: 'u',
  );

  // The server granted a session and this device could not store it (#726).
  // Its own kind, so the copy can point at the device rather than the server.
  group('a session this device could not store', () {
    const deviceStorage = AuthDeviceStorageException();

    blocTest<AuthBloc, AuthBlocState>(
      'sign-in mapping: AuthDeviceStorageException → AuthFailureDeviceStorage',
      build: () {
        stubSignIn(() => Future.error(deviceStorage));
        return AuthBloc(authRepository: mockRepo);
      },
      seed: () => const AuthUnauthenticated(),
      act: (bloc) => bloc.add(signIn),
      expect: () => [const AuthLoading(), const AuthFailureDeviceStorage()],
    );

    blocTest<AuthBloc, AuthBlocState>(
      'register mapping: AuthDeviceStorageException → '
      'AuthFailureDeviceStorage',
      build: () {
        stubSignUp(() => Future.error(deviceStorage));
        return AuthBloc(authRepository: mockRepo);
      },
      seed: () => const AuthUnauthenticated(),
      act: (bloc) => bloc.add(register),
      expect: () => [const AuthLoading(), const AuthFailureDeviceStorage()],
    );
  });

  // Nothing raw may leave a credential handler (#181): a throw no arm models
  // used to strand the form on AuthLoading for good (#726).
  group('a throw that is not an AuthException', () {
    final unexpected = StateError('x');

    // Not `blocTest`'s `errors:`, which would let a handler stranded on
    // AuthLoading pass: see `recordBlocErrors`.
    late List<Object> reported;
    setUp(() => reported = recordBlocErrors());

    // The throw goes to onError, not into the state: logging it from both
    // would count one fault twice.
    final reportedServerFailure = isA<AuthFailureServer>().having(
      (s) => s.cause,
      'cause',
      isNull,
    );

    blocTest<AuthBloc, AuthBlocState>(
      'sign-in: a non-AuthException throw lands on AuthFailureServer and is '
      'reported through onError',
      build: () {
        stubSignIn(() => Future.error(unexpected));
        return AuthBloc(authRepository: mockRepo);
      },
      seed: () => const AuthUnauthenticated(),
      act: (bloc) => bloc.add(signIn),
      expect: () => [const AuthLoading(), reportedServerFailure],
      verify: (_) => expect(reported, [same(unexpected)]),
    );

    blocTest<AuthBloc, AuthBlocState>(
      'register: a non-AuthException throw lands on AuthFailureServer and is '
      'reported through onError',
      build: () {
        stubSignUp(() => Future.error(unexpected));
        return AuthBloc(authRepository: mockRepo);
      },
      seed: () => const AuthUnauthenticated(),
      act: (bloc) => bloc.add(register),
      expect: () => [const AuthLoading(), reportedServerFailure],
      verify: (_) => expect(reported, [same(unexpected)]),
    );

    // As for a modelled failure (#280): on web another tab's sign-in reaches
    // this bloc through the repository while the call is out.
    group('keeps a session that arrived meanwhile', () {
      late StreamController<AuthState> repoStates;
      late Completer<AuthResponse> gate;

      setUp(() {
        repoStates = StreamController<AuthState>();
        addTearDown(repoStates.close);
        when(
          () => mockRepo.watchAuthState(),
        ).thenAnswer((_) => repoStates.stream);
      });

      for (final (name, event, stub) in [
        ('sign-in', signIn as AuthEvent, stubSignIn),
        ('register', register as AuthEvent, stubSignUp),
      ]) {
        blocTest<AuthBloc, AuthBlocState>(
          '$name backstop keeps a session that arrived meanwhile, and still '
          'reports the error',
          build: () {
            // Made here, inside `blocTest`'s error zone: an error can't
            // cross into it from a future made in `setUp`, so the handler
            // would never see it.
            gate = Completer<AuthResponse>();
            stub(() => gate.future);
            return AuthBloc(authRepository: mockRepo);
          },
          seed: () => const AuthUnauthenticated(),
          act: (bloc) async {
            bloc.add(event);
            await pumpEventQueue();
            repoStates.add(AuthStateAuthenticated(session: testAuthResponse()));
            await pumpEventQueue();
            gate.completeError(unexpected);
          },
          expect: () => [
            const AuthLoading(),
            AuthAuthenticated(session: testAuthResponse()),
          ],
          // Kept, but not lost: nothing raw goes unreported (#181).
          verify: (_) => expect(reported, [same(unexpected)]),
        );
      }
    });
  });
}
