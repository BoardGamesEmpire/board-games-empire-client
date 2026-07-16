import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/web_auth_repository_impl.dart';

class MockDio extends Mock implements Dio {}

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
);

/// Pins the web side of the [AuthRepository.signOut] contract (#37
/// review). [WebAuthRepositoryImpl] has no persisted session material of
/// its own (the browser owns the httpOnly cookie), so — unlike the native
/// impl — its sign-out has nothing that can fail persistence:
/// it NEVER throws, and the in-memory transition to
/// [AuthStateUnauthenticated] is unconditional (`finally`). These tests
/// lock that in so a future refactor cannot reintroduce a path where the
/// state stream re-asserts an ended session.
void main() {
  late MockDio mockDio;
  late WebAuthRepositoryImpl repo;

  setUp(() {
    mockDio = MockDio();
    repo = WebAuthRepositoryImpl(identity: _identity(), dio: mockDio);
  });

  tearDown(() async => repo.onDispose());

  group('signOut() invariant (web)', () {
    test('completes and transitions to unauthenticated on success', () async {
      when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenAnswer(
        (_) async => Response<void>(
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );

      await expectLater(repo.signOut(), completes);

      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });

    test('a failed server call does not throw — best-effort — and still '
        'transitions to unauthenticated', () async {
      when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: ''),
        ),
      );

      await expectLater(repo.signOut(), completes);

      expect(
        await repo.watchAuthState().first,
        const AuthStateUnauthenticated(),
      );
    });

    test('an ended (authenticated → signed-out) session is never '
        're-asserted by the stream, even when the server call fails', () async {
      // Reach an authenticated state first via the session endpoint.
      when(
        () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
      ).thenAnswer(
        (_) async => Response(
          data: {
            'session': {
              'id': 'sess-1',
              'token': 'session-tok-abc',
              'expiresAt': '2099-01-01T00:00:00.000Z',
              'userId': 'user-1',
            },
            'user': {
              'id': 'user-1',
              'name': 'testuser',
              'email': 'web@example.com',
              'emailVerified': true,
              'createdAt': '2024-01-01T00:00:00.000Z',
              'updatedAt': '2024-01-01T00:00:00.000Z',
            },
          },
          statusCode: 200,
          requestOptions: RequestOptions(path: ''),
        ),
      );
      await repo.getSession();
      expect(await repo.watchAuthState().first, isA<AuthStateAuthenticated>());

      when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: ''),
        ),
      );

      final emissions = <AuthState>[];
      final sub = repo.watchAuthState().listen(emissions.add);
      await pumpEventQueue();

      await expectLater(repo.signOut(), completes);
      await pumpEventQueue();
      await sub.cancel();

      final afterSignOut = emissions.skipWhile(
        (s) => s is! AuthStateUnauthenticated,
      );
      expect(afterSignOut, isNotEmpty);
      expect(afterSignOut.whereType<AuthStateAuthenticated>(), isEmpty);
    });
  });
}
