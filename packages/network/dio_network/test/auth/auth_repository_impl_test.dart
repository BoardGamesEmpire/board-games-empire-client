import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:dio_network/src/auth/auth_repository_impl.dart';
import 'package:dio_network/src/auth/token_storage_service.dart';

class MockDio extends Mock implements Dio {}

class MockTokenStorage extends Mock implements TokenStorageService {}

// Endpoints are relative paths resolved against the user-supplied base URL by
// the per-server Dio (set via DioFactory). The repository passes them through
// to Dio unchanged.
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

// BetterAuth wire shape: the display name is under `name` (mapped to
// AuthUser.username), and all fields are camelCase.
Map<String, dynamic> _wireUser() => {
  'id': 'user-1',
  'name': 'testuser',
  'email': 'test@example.com',
  'emailVerified': true,
  'createdAt': '2024-01-01T00:00:00.000Z',
  'updatedAt': '2024-01-01T00:00:00.000Z',
};

Map<String, dynamic> _signInJson() => {
  'token': 'session-tok-abc',
  'user': _wireUser(),
};

Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': 'session-tok-abc',
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': 'user-1',
  },
  'user': _wireUser(),
};

Response<Map<String, dynamic>> _ok(Map<String, dynamic> data) => Response(
  data: data,
  statusCode: 200,
  requestOptions: RequestOptions(path: ''),
);

Response<Map<String, dynamic>> _status(int code, [Map<String, dynamic>? data]) =>
    Response(
      data: data,
      statusCode: code,
      requestOptions: RequestOptions(path: ''),
    );

void main() {
  late MockDio mockDio;
  late MockTokenStorage mockStorage;
  late AuthRepositoryImpl repo;

  final expiry = DateTime(2099).toUtc();

  setUp(() {
    mockDio = MockDio();
    // The repository's TEMP #101 diagnostics read options.baseUrl on
    // failure paths.
    when(
      () => mockDio.options,
    ).thenReturn(BaseOptions(baseUrl: 'https://api.example.com'));
    mockStorage = MockTokenStorage();
    repo = AuthRepositoryImpl(
      identity: _identity(),
      tokenStorage: mockStorage,
      dio: mockDio,
    );
  });

  tearDown(() async => repo.onDispose());

  void stubStore() => when(
    () => mockStorage.store(
      token: any(named: 'token'),
      expiresAt: any(named: 'expiresAt'),
    ),
  ).thenAnswer((_) async {});

  void stubRetrieve({String token = 'session-tok-abc'}) => when(
    () => mockStorage.retrieve(),
  ).thenAnswer((_) async => StoredToken(token: token, expiresAt: expiry));

  void stubClear() => when(() => mockStorage.clear()).thenAnswer((_) async {});

  group('AuthRepositoryImpl', () {
    group('signIn()', () {
      test('returns AuthResponse on success', () async {
        stubStore();
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-in/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _ok(_signInJson()));
        stubRetrieve();
        when(
          () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
        ).thenAnswer((_) async => _ok(_sessionJson()));

        final result = await repo.signIn(email: 'a@b.com', password: 'pass');
        expect(result.token, 'session-tok-abc');
        expect(result.user.username, 'testuser');
      });

      test('throws AuthInvalidCredentialsException on 401', () {
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

      test('throws AuthNetworkException on connection error', () {
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
      test('throws AuthRegistrationDisabledException when disabled', () {
        final disabledRepo = AuthRepositoryImpl(
          identity: _identity().copyWith(
            strategies: [
              const EmailAndPasswordStrategy(
                signUpDisabled: true,
                signInEndpoint: '$_kAuthBase/sign-in/email',
              ),
            ],
          ),
          tokenStorage: mockStorage,
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

        addTearDown(disabledRepo.onDispose);
      });

      test('throws AuthEmailAlreadyExistsException on 409', () {
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

      test('throws AuthEmailAlreadyExistsException on BetterAuth 422 with '
          'body code USER_ALREADY_EXISTS (BetterAuth never uses 409)', () {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            any(),
            data: any(named: 'data'),
          ),
        ).thenAnswer(
          (_) async => _status(422, {
            'code': 'USER_ALREADY_EXISTS',
            'message': 'User already exists',
          }),
        );

        expect(
          () => repo.signUp(email: 'dup@b.com', password: 'p', username: 'u'),
          throwsA(isA<AuthEmailAlreadyExistsException>()),
        );
      });

      test('throws AuthEmailAlreadyExistsException on the versioned code '
          'USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL (verbatim body observed '
          'from the BGE dev server)', () {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            any(),
            data: any(named: 'data'),
          ),
        ).thenAnswer(
          (_) async => _status(422, {
            'message': 'User already exists. Use another email.',
            'code': 'USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL',
          }),
        );

        expect(
          () => repo.signUp(email: 'dup@b.com', password: 'p', username: 'u'),
          throwsA(isA<AuthEmailAlreadyExistsException>()),
        );
      });

      test('a 422 WITHOUT the USER_ALREADY_EXISTS code stays a generic '
          'AuthServerException (no over-mapping of validation failures)', () {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            any(),
            data: any(named: 'data'),
          ),
        ).thenAnswer(
          (_) async =>
              _status(422, {'code': 'OTHER', 'message': 'Invalid input'}),
        );

        expect(
          () => repo.signUp(email: 'a@b.com', password: 'p', username: 'u'),
          throwsA(isA<AuthServerException>()),
        );
      });
    });

    group('getSession()', () {
      test(
        'returns null and emits unauthenticated when no stored token',
        () async {
          when(() => mockStorage.retrieve()).thenAnswer((_) async => null);

          final future = expectLater(
            repo.watchAuthState().take(2),
            emitsInOrder([
              isA<AuthStateUnknown>(),
              isA<AuthStateUnauthenticated>(),
            ]),
          );

          expect(await repo.getSession(), isNull);
          await future;
        },
      );

      test(
        'clears token and returns null on 401 from session endpoint',
        () async {
          stubRetrieve();
          stubClear();
          when(
            () => mockDio.get<Map<String, dynamic>>(any()),
          ).thenAnswer((_) async => _status(401));

          expect(await repo.getSession(), isNull);
          verify(() => mockStorage.clear()).called(1);
        },
      );

      test('updates stored expiry from session response', () async {
        stubRetrieve();
        when(
          () => mockDio.get<Map<String, dynamic>>(any()),
        ).thenAnswer((_) async => _ok(_sessionJson()));
        stubStore();

        await repo.getSession();

        verify(
          () => mockStorage.store(
            token: 'session-tok-abc',
            expiresAt: any(named: 'expiresAt'),
          ),
        ).called(1);
      });
    });

    group('signOut()', () {
      test('clears token regardless of server response', () async {
        stubClear();
        // signOut() reads the token to authenticate the best-effort POST
        // before latching; none stored here.
        when(() => mockStorage.retrieve()).thenAnswer((_) async => null);
        when(
          () => mockDio.post<void>(any(), options: any(named: 'options')),
        ).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        await repo.signOut();
        verify(() => mockStorage.clear()).called(1);
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
      test('signIn throws AuthServerException', () {
        final noStrategyRepo = AuthRepositoryImpl(
          identity: _identity().copyWith(strategies: []),
          tokenStorage: mockStorage,
          dio: mockDio,
        );

        expect(
          () => noStrategyRepo.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<AuthServerException>()),
        );

        addTearDown(noStrategyRepo.onDispose);
      });
    });
  });
}
