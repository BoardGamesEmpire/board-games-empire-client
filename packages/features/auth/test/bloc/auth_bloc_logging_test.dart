import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

/// Failure logging (#100) is centralised in `onTransition` (warn/error by
/// severity bucket) plus `onError` (backstop). These tests drive the bloc
/// through each seam and assert the level of the record it emits on its own
/// `bge.auth.bloc` logger, captured off `Logger.root` (delivery is
/// synchronous — package:logging uses a sync broadcast controller).
void main() {
  late MockAuthRepository repo;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> sub;
  late Level previous;

  setUp(() {
    repo = MockAuthRepository();
    when(() => repo.watchAuthState()).thenAnswer((_) => const Stream.empty());
    records = [];
    previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    sub = Logger.root.onRecord.listen(records.add);
  });
  tearDown(() async {
    await sub.cancel();
    Logger.root.level = previous;
  });

  Iterable<LogRecord> fromBloc() =>
      records.where((r) => r.loggerName == 'bge.auth.bloc');
  Iterable<LogRecord> warns() =>
      fromBloc().where((r) => r.level == Level.WARNING);
  Iterable<LogRecord> errors() =>
      fromBloc().where((r) => r.level == Level.SEVERE);

  blocTest<AuthBloc, AuthBlocState>(
    'warns (not errors) on invalid credentials — a recoverable outcome',
    build: () {
      when(
        () => repo.signIn(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenThrow(const AuthInvalidCredentialsException());
      return AuthBloc(authRepository: repo);
    },
    act: (b) =>
        b.add(const AuthSignInRequested(email: 'a@b.co', password: 'x')),
    verify: (_) {
      expect(warns(), isNotEmpty);
      expect(errors(), isEmpty);
    },
  );

  blocTest<AuthBloc, AuthBlocState>(
    'errors on an unexpected server failure (AuthFailureServer)',
    build: () {
      when(
        () => repo.signIn(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenThrow(const AuthServerException(message: 'boom', statusCode: 500));
      return AuthBloc(authRepository: repo);
    },
    act: (b) =>
        b.add(const AuthSignInRequested(email: 'a@b.co', password: 'x')),
    verify: (_) => expect(errors(), isNotEmpty),
  );

  blocTest<AuthBloc, AuthBlocState>(
    'warns when a session check cannot complete (network) — indeterminate',
    build: () {
      when(
        () => repo.getSession(),
      ).thenThrow(const AuthNetworkException(message: 'offline'));
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthSessionCheckRequested()),
    verify: (_) {
      expect(warns(), isNotEmpty);
      expect(errors(), isEmpty);
    },
  );

  blocTest<AuthBloc, AuthBlocState>(
    'errors when a session check hits an unexpected non-auth fault',
    build: () {
      when(() => repo.getSession()).thenThrow(StateError('locked keychain'));
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthSessionCheckRequested()),
    verify: (_) => expect(errors(), isNotEmpty),
  );

  blocTest<AuthBloc, AuthBlocState>(
    'errors via the onError backstop when sign-out throws unexpectedly',
    build: () {
      when(() => repo.signOut()).thenThrow(StateError('disk gone'));
      return AuthBloc(authRepository: repo);
    },
    act: (b) => b.add(const AuthSignOutRequested()),
    // Sign-out still flips to Unauthenticated; the throw rides addError,
    // which onError logs at error.
    errors: () => [isA<StateError>()],
    verify: (_) => expect(errors(), isNotEmpty),
  );
}
