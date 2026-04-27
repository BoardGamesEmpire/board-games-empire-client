import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/web_auth_repository_impl.dart';

class MockDio extends Mock implements Dio {}

const _kAuthBase = 'https://api.example.com/api/auth';

ServerIdentity _identity({bool signUpDisabled = false}) => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBaseUrl: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
  strategies: [
    EmailAndPasswordStrategy(
      signUpDisabled: signUpDisabled,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: signUpDisabled ? null : '$_kAuthBase/sign-up/email',
    ),
  ],
);

Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': 'session-tok-web',
    'expires_at': '2099-01-01T00:00:00.000Z',
    'user_id': 'user-1',
  },
  'user': {'id': 'user-1', 'username': 'webuser'},
};

Response<Map<String, dynamic>> _ok(Map<String, dynamic> data) => Response(
  data: data,
  statusCode: 200,
  requestOptions: RequestOptions(path: ''),
);

Response<Map<String, dynamic>> _status(int code) => Response(
  data: null,
  statusCode: code,
  requestOptions: RequestOptions(path: ''),
);

void main() {
  late MockDio mockDio;
  late WebAuthRepositoryImpl repo;

  setUp(() {
    mockDio = MockDio();
    when(() => mockDio.interceptors).thenReturn(Interceptors());
    repo = WebAuthRepositoryImpl(identity: _identity(), dio: mockDio);
  });

  tearDown(() async => repo.dispose());

  group('WebAuthRepositoryImpl', () {
    group('signIn()', () {
      test(
        'returns session from getSession() after successful sign-in',
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              '$_kAuthBase/sign-in/email',
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _ok({}));

          when(
            () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
          ).thenAnswer((_) async => _ok(_sessionJson()));

          final result = await repo.signIn(email: 'a@b.com', password: 'pass');

          expect(result.token, 'session-tok-web');
          expect(result.user.username, 'webuser');
          expect(result.expiresAt, isNotNull);
        },
      );

      test(
        'throws AuthServerException when session unretrievable after sign-in',
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              any(),
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _ok({}));

          when(
            () => mockDio.get<Map<String, dynamic>>(any()),
          ).thenAnswer((_) async => _status(401));

          expect(
            () => repo.signIn(email: 'a@b.com', password: 'pass'),
            throwsA(isA<AuthServerException>()),
          );
        },
      );

      test('throws AuthInvalidCredentialsException on 401', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            any(),
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _status(401));

        expect(
          () => repo.signIn(email: 'a@b.com', password: 'wrong'),
          throwsA(isA<AuthInvalidCredentialsException>()),
        );
      });

      test('throws AuthNetworkException on connection error', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            any(),
            data: any(named: 'data'),
          ),
        ).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        expect(
          () => repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(isA<AuthNetworkException>()),
        );
      });
    });

    group('signUp()', () {
      test(
        'throws AuthRegistrationDisabledException when sign-up disabled',
        () async {
          final disabledRepo = WebAuthRepositoryImpl(
            identity: _identity(signUpDisabled: true),
            dio: mockDio,
          );

          expect(
            () => disabledRepo.signUp(
              email: 'a@b.com',
              password: 'p',
              username: 'u',
            ),
            throwsA(isA<AuthRegistrationDisabledException>()),
          );

          await disabledRepo.dispose();
        },
      );

      test('throws AuthEmailAlreadyExistsException on 409', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            any(),
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _status(409));

        expect(
          () => repo.signUp(email: 'dup@b.com', password: 'p', username: 'u'),
          throwsA(isA<AuthEmailAlreadyExistsException>()),
        );
      });
    });

    group('getSession()', () {
      test('returns AuthResponse with token and user on 200', () async {
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _ok(_sessionJson()));

        final result = await repo.getSession();

        expect(result?.token, 'session-tok-web');
        expect(result?.user.username, 'webuser');
      });

      test('returns null and emits unauthenticated on 401', () async {
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _status(401));

        expect(await repo.getSession(), isNull);

        await expectLater(
          repo.watchAuthState().take(2),
          emitsInOrder([anything, isA<AuthStateUnauthenticated>()]),
        );
      });

      test('emits AuthStateAuthenticated on success', () async {
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _ok(_sessionJson()));

        await repo.getSession();

        await expectLater(
          repo.watchAuthState().take(2),
          emitsInOrder([anything, isA<AuthStateAuthenticated>()]),
        );
      });
    });

    group('getCachedSession()', () {
      test('delegates to getSession() — always makes a network call', () async {
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _ok(_sessionJson()));

        await repo.getCachedSession();

        verify(() => mockDio.get<Map<String, dynamic>>(any())).called(1);
      });
    });

    group('signOut()', () {
      test('emits unauthenticated even when server call fails', () async {
        when(() => mockDio.post<void>(any())).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        await repo.signOut();

        await expectLater(
          repo.watchAuthState().take(2),
          emitsInOrder([anything, isA<AuthStateUnauthenticated>()]),
        );
      });

      test('POSTs to the sign-out endpoint', () async {
        when(() => mockDio.post<void>(any())).thenAnswer(
          (_) async => Response(
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        await repo.signOut();

        verify(() => mockDio.post<void>('$_kAuthBase/sign-out')).called(1);
      });
    });

    group('watchAuthState()', () {
      test('replays AuthStateUnknown as initial state', () async {
        await expectLater(
          repo.watchAuthState().take(1),
          emits(isA<AuthStateUnknown>()),
        );
      });
    });

    group('no email strategy', () {
      test('signIn throws AuthServerException', () async {
        final noStrategyRepo = WebAuthRepositoryImpl(
          identity: _identity().copyWith(strategies: []),
          dio: mockDio,
        );

        expect(
          () => noStrategyRepo.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<AuthServerException>()),
        );

        await noStrategyRepo.dispose();
      });
    });
  });
}
