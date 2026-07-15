import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:dio_network/src/auth/auth_repository_impl.dart';
import 'package:dio_network/src/auth/token_storage_service.dart';
import 'package:dio_network/src/network/token_interceptor.dart';

class MockDio extends Mock implements Dio {}

class MockTokenStorage extends Mock implements TokenStorageService {}

const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
  strategies: [
    const EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

/// Pins the [AuthRepository.signOut] persistence invariant (#37 review):
/// the in-memory transition to [AuthStateUnauthenticated] is
/// UNCONDITIONAL — it happens even when clearing the persisted token
/// fails — and the failure surfaces as [AuthSignOutPersistenceException]
/// with the underlying fault as [AuthException.cause]. Without this,
/// `watchAuthState` could re-assert a session the user just ended (the
/// sign-out resurrection hole).
void main() {
  late MockDio mockDio;
  late MockTokenStorage mockStorage;
  late AuthRepositoryImpl repo;

  setUp(() {
    mockDio = MockDio();
    mockStorage = MockTokenStorage();
    repo = AuthRepositoryImpl(
      identity: _identity(),
      tokenStorage: mockStorage,
      dio: mockDio,
    );
    // signOut() reads the token (to authenticate the best-effort POST)
    // before latching; default to none, overridden where a token matters.
    when(() => mockStorage.retrieve()).thenAnswer((_) async => null);
  });

  tearDown(() async => repo.onDispose());

  void stubSignOutPostOk() =>
      when(
        () => mockDio.post<void>(
          '$_kAuthBase/sign-out',
          options: any(named: 'options'),
        ),
      ).thenAnswer(
        (_) async => Response<void>(
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );

  void stubSignOutPostFails() =>
      when(
        () => mockDio.post<void>(
          '$_kAuthBase/sign-out',
          options: any(named: 'options'),
        ),
      ).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: ''),
        ),
      );

  group('signOut() persistence invariant', () {
    test('happy path: completes and transitions to unauthenticated', () async {
      stubSignOutPostOk();
      when(() => mockStorage.clear()).thenAnswer((_) async {});

      await repo.signOut();

      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
      verify(() => mockStorage.clear()).called(1);
    });

    test('a failed server call alone does not throw — best-effort — and '
        'still transitions to unauthenticated', () async {
      stubSignOutPostFails();
      when(() => mockStorage.clear()).thenAnswer((_) async {});

      await expectLater(repo.signOut(), completes);

      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });

    test('a failed storage clear throws AuthSignOutPersistenceException '
        'with the fault preserved as cause — AND the state has still '
        'transitioned to unauthenticated', () async {
      stubSignOutPostOk();
      final storageFault = StateError('keychain unavailable');
      when(() => mockStorage.clear()).thenThrow(storageFault);

      final emissions = <AuthState>[];
      final sub = repo.watchAuthState().listen(emissions.add);
      await pumpEventQueue();

      await expectLater(
        repo.signOut(),
        throwsA(
          isA<AuthSignOutPersistenceException>().having(
            (e) => e.cause,
            'cause',
            same(storageFault),
          ),
        ),
      );
      await pumpEventQueue();
      await sub.cancel();

      // The live stream saw the transition despite the throw…
      expect(emissions.last, const AuthStateUnauthenticated());
      // …and the repository's replayed current state agrees: a mirror
      // subscribing later can only confirm the sign-out, never resurrect
      // the ended session.
      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });

    test('server call AND storage clear both failing still yields the '
        'typed exception and the unauthenticated transition', () async {
      stubSignOutPostFails();
      final storageFault = StateError('keychain unavailable');
      when(() => mockStorage.clear()).thenThrow(storageFault);

      await expectLater(
        repo.signOut(),
        throwsA(isA<AuthSignOutPersistenceException>()),
      );

      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });

    test('an ended (authenticated → signed-out) session is never '
        're-asserted by the stream after a failed clear', () async {
      // Reach an authenticated state first, via a stored token + a valid
      // session response.
      when(() => mockStorage.retrieve()).thenAnswer(
        (_) async => StoredToken(
          token: 'session-tok-abc',
          expiresAt: DateTime(2099).toUtc(),
        ),
      );
      when(
        () => mockStorage.store(
          token: any(named: 'token'),
          expiresAt: any(named: 'expiresAt'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
      ).thenAnswer(
        (_) async => Response(
          data: {
            'session': {
              'id': 'sess-1',
              'token': 'session-tok-abc',
              'expires_at': '2099-01-01T00:00:00.000Z',
              'user_id': 'user-1',
            },
            'user': {'id': 'user-1', 'username': 'testuser'},
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );
      await repo.getSession();
      expect(await repo.watchAuthState().first, isA<AuthStateAuthenticated>());

      stubSignOutPostOk();
      when(
        () => mockStorage.clear(),
      ).thenThrow(StateError('keychain unavailable'));

      final emissions = <AuthState>[];
      final sub = repo.watchAuthState().listen(emissions.add);
      await pumpEventQueue();

      await expectLater(
        repo.signOut(),
        throwsA(isA<AuthSignOutPersistenceException>()),
      );
      await pumpEventQueue();
      await sub.cancel();

      // Replay (authenticated) + the sign-out transition — and nothing
      // authenticated ever again after it.
      final afterSignOut = emissions.skipWhile(
        (s) => s is! AuthStateUnauthenticated,
      );
      expect(afterSignOut, isNotEmpty);
      expect(afterSignOut.whereType<AuthStateAuthenticated>(), isEmpty);
    });

    test('the best-effort sign-out POST carries the captured token '
        'explicitly, so the latch set by clear() cannot strip its '
        'Authorization header (PR #99 review)', () async {
      when(() => mockStorage.retrieve()).thenAnswer(
        (_) async =>
            StoredToken(token: 'live-tok', expiresAt: DateTime(2099).toUtc()),
      );
      when(() => mockStorage.clear()).thenAnswer((_) async {});
      stubSignOutPostOk();

      await repo.signOut();
      // The POST is fire-and-forget; let it reach the Dio call.
      await pumpEventQueue();

      final captured =
          verify(
                () => mockDio.post<void>(
                  '$_kAuthBase/sign-out',
                  options: captureAny(named: 'options'),
                ),
              ).captured.single
              as Options;

      // Authenticated by the captured token, and opting out of the
      // interceptor so latch timing is irrelevant.
      expect(captured.headers?['Authorization'], 'Bearer live-tok');
      expect(captured.extra?[TokenInterceptor.skipAuthKey], isTrue);
    });

    test('a keychain read failure while capturing the token does NOT abort '
        'sign-out — clear() still runs and the state transitions to '
        'unauthenticated (PR #99 review)', () async {
      // Capturing the token for the best-effort POST reads storage; a read
      // fault must not skip the unconditional local sign-out.
      when(
        () => mockStorage.retrieve(),
      ).thenThrow(StateError('keychain locked'));
      when(() => mockStorage.clear()).thenAnswer((_) async {});
      stubSignOutPostOk();

      await expectLater(repo.signOut(), completes);

      verify(() => mockStorage.clear()).called(1);
      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });
  });
}
