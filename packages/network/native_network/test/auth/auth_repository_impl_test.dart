import 'dart:async';
import 'dart:convert';

import 'package:bge_test_support/domain.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/dto.dart';
import 'package:native_network/src/auth/auth_repository_impl.dart';
import 'package:native_network/src/auth/token_storage_service.dart';
import 'package:observability/observability.dart' show LogRecordFormatter;

class MockDio extends Mock implements Dio {}

class MockTokenStorage extends Mock implements TokenStorageService {}

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

/// `session.token` is deliberately distinct from the sign-in grant's token:
/// the client must adopt the server-vended credential on revalidation, and
/// a shared fixture string would let a regression pass unnoticed.
const _kServerVendedToken = 'session-tok-renewed';

Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': _kServerVendedToken,
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': 'user-1',
  },
  'user': _wireUser(),
};

Response<String> _ok(Map<String, dynamic> data) => Response(
  data: jsonEncode(data),
  statusCode: 200,
  requestOptions: RequestOptions(),
);

Response<String> _status(int code, [Map<String, dynamic>? data]) => Response(
  data: data == null ? null : jsonEncode(data),
  statusCode: code,
  requestOptions: RequestOptions(),
);

/// A response whose body is passed through as given, for bodies that are
/// not a JSON envelope at all.
Response<String> _raw(int code, String? body) => Response(
  data: body,
  statusCode: code,
  requestOptions: RequestOptions(),
);

void main() {
  late MockDio mockDio;
  late MockTokenStorage mockStorage;
  late AuthRepositoryImpl repo;

  final expiry = DateTime(2099).toUtc();
  final persistedAt = DateTime.utc(2026);

  setUp(() {
    mockDio = MockDio();
    // The repository's TEMP #101 diagnostics read options.baseUrl on
    // failure paths.
    when(() => mockDio.options).thenReturn(BaseOptions(baseUrl: testServerUrl));
    mockStorage = MockTokenStorage();
    // The identity's endpoints are relative paths, which the per-server Dio
    // (set via DioFactory) resolves against the user-supplied base URL. The
    // repository passes them through to Dio unchanged, so the stubs below
    // match the bare paths.
    repo = AuthRepositoryImpl(
      identity: testServerIdentity(),
      serverUrl: testServerUrl,
      tokenStorage: mockStorage,
      dio: mockDio,
    );
  });

  tearDown(() async => repo.onDispose());

  void stubStore() => when(
    () => mockStorage.store(
      token: any(named: 'token'),
      expiresAt: any(named: 'expiresAt'),
      persistedAt: any(named: 'persistedAt'),
      user: any(named: 'user'),
    ),
  ).thenAnswer((_) async {});

  void stubRetrieve({String token = 'session-tok-abc'}) =>
      when(() => mockStorage.retrieve()).thenAnswer(
        (_) async => StoredSession(
          token: token,
          expiresAt: expiry,
          persistedAt: persistedAt,
          user: AuthUser.fromJson(_wireUser()),
        ),
      );

  void stubClear() => when(() => mockStorage.clear()).thenAnswer((_) async {});

  group('AuthRepositoryImpl', () {
    group('signIn()', () {
      test('returns AuthResponse on success', () async {
        stubStore();
        when(
          () => mockDio.post<String>(
            '$testAuthBasePath/sign-in/email',
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(_signInJson()));
        stubRetrieve();
        when(
          () => mockDio.get<String>(
            '$testAuthBasePath/get-session',
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(_sessionJson()));

        final result = await repo.signIn(email: 'a@b.com', password: 'pass');
        expect(
          result.token,
          _kServerVendedToken,
          reason: 'sign-in reconciles, adopting the session endpoint token',
        );
        expect(result.user.username, 'testuser');
      });

      test('throws AuthInvalidCredentialsException on 401', () {
        when(
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _status(401));

        expect(
          () => repo.signIn(email: 'a@b.com', password: 'wrong'),
          throwsA(isA<AuthInvalidCredentialsException>()),
        );
      });

      // BetterAuth refuses an unverified sign-in with a 403 after the
      // password check passes (#394). The status alone reads as a wrong
      // password, so only the body code can tell the two apart.
      test('a 403 EMAIL_NOT_VERIFIED is an unverified email, not a wrong '
          'password', () {
        when(
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer(
          (_) async => _status(403, {
            'code': 'EMAIL_NOT_VERIFIED',
            'message': 'Email not verified',
          }),
        );

        expect(
          () => repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(isA<AuthEmailNotVerifiedException>()),
        );
      });

      test('a 403 without a known code stays invalid credentials', () {
        when(
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _status(403, {'code': 'SOMETHING_ELSE'}));

        expect(
          () => repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(isA<AuthInvalidCredentialsException>()),
        );
      });

      test('a 403 that is not a readable envelope stays invalid '
          'credentials', () async {
        for (final body in ['<html><body>Forbidden</body></html>', '', null]) {
          when(
            () => mockDio.post<String>(
              any(),
              data: any(named: 'data'),
              options: any(named: 'options'),
            ),
          ).thenAnswer((_) async => _raw(403, body));

          await expectLater(
            repo.signIn(email: 'a@b.com', password: 'pass'),
            throwsA(isA<AuthInvalidCredentialsException>()),
            reason: 'body: ${body == null ? 'null' : "'$body'"}',
          );
        }
      });

      test('a 401 carrying a code stays invalid credentials', () {
        when(
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _status(401, {'code': 'EMAIL_NOT_VERIFIED'}));

        expect(
          () => repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(isA<AuthInvalidCredentialsException>()),
        );
      });

      test('throws AuthNetworkException on connection error', () {
        when(
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(),
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
          identity: testServerIdentity().copyWith(
            strategies: [testEmailAndPasswordStrategy(signUpDisabled: true)],
          ),
          serverUrl: testServerUrl,
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
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
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
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
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
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
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
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
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

      // Discovery said registration was open, so the request goes out, and
      // the server's route gate refuses it (#443).
      test('a 403 REGISTRATION_DISABLED means registration closed after '
          'discovery was read', () async {
        when(
          () => mockDio.post<String>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer(
          (_) async => _status(403, {
            'code': 'REGISTRATION_DISABLED',
            'message': 'Registration is disabled on this server.',
          }),
        );

        await expectLater(
          repo.signUp(email: 'a@b.com', password: 'p', username: 'u'),
          throwsA(isA<AuthRegistrationDisabledException>()),
        );
        verify(
          () => mockDio.post<String>(
            '$testAuthBasePath/sign-up/email',
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).called(1);
      });
    });

    // #291 made `AuthResponse.token` nullable so web can stop carrying a
    // credential it never reads. Native does read it, and this is the
    // envelope BetterAuth documents when email verification is required or
    // `autoSignIn` is off — so on native it is a grant that cannot be
    // acted on.
    //
    // Before the field was nullable this shape failed inside `fromJson`,
    // and a raw parse error slips past every `on AuthException` clause in
    // AuthBloc and strands the form on AuthLoading. The guard below is
    // what keeps that from becoming a *silent* failure now that the shape
    // parses: it has to leave as a modelled AuthException, and nothing may
    // be persisted on the way out.
    //
    // It leaves as AuthSessionNotGrantedException rather than a server fault
    // (#331): the server did exactly what it was configured to do, and the
    // generic "something went wrong on the server" invited a retry that can
    // only ever produce the same answer.
    group('a grant envelope with no token', () {
      Map<String, dynamic> tokenlessGrant() => {
        ..._signInJson(),
        'token': null,
      };

      void verifyNothingPersisted() {
        verifyNever(
          () => mockStorage.store(
            token: any(named: 'token'),
            expiresAt: any(named: 'expiresAt'),
            persistedAt: any(named: 'persistedAt'),
            user: any(named: 'user'),
          ),
        );
      }

      test('fails sign-in as not granted, persisting nothing', () async {
        stubStore();
        when(
          () => mockDio.post<String>(
            '$testAuthBasePath/sign-in/email',
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(tokenlessGrant()));

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(isA<AuthSessionNotGrantedException>()),
        );
        verifyNothingPersisted();
      });

      test('fails sign-up as not granted, persisting nothing', () async {
        stubStore();
        when(
          () => mockDio.post<String>(
            '$testAuthBasePath/sign-up/email',
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(tokenlessGrant()));

        await expectLater(
          repo.signUp(email: 'a@b.com', password: 'p', username: 'u'),
          throwsA(isA<AuthSessionNotGrantedException>()),
        );
        verifyNothingPersisted();
      });

      test('leaves the auth state untouched', () async {
        stubStore();
        when(
          () => mockDio.post<String>(
            '$testAuthBasePath/sign-in/email',
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(tokenlessGrant()));

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(isA<AuthSessionNotGrantedException>()),
        );
        expect(repo.currentAuthState, isA<AuthStateUnknown>());
      });

      test('never reaches the session endpoint', () async {
        stubStore();
        when(
          () => mockDio.post<String>(
            '$testAuthBasePath/sign-in/email',
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(tokenlessGrant()));

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(isA<AuthSessionNotGrantedException>()),
        );
        verifyNever(
          () => mockDio.get<String>(any(), options: any(named: 'options')),
        );
      });
    });

    // The server granted a session and this device could not keep it (#726).
    // A raw storage error used to leave the grant, slip past every
    // `on AuthException` clause in AuthBloc and strand the form on its
    // loading state. It now leaves as its own reason, and the session nobody
    // holds is revoked best-effort with the token still in memory.
    group('a grant this device cannot store', () {
      final storageFault = PlatformException(code: 'x');
      final signOutEndpoint = testServerIdentity().signOutEndpoint;

      void stubGrant() => when(
        () => mockDio.post<String>(
          '$testAuthBasePath/sign-in/email',
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => _ok(_signInJson()));

      void stubStoreFails() => when(
        () => mockStorage.store(
          token: any(named: 'token'),
          expiresAt: any(named: 'expiresAt'),
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      ).thenAnswer((_) => Future.error(storageFault));

      /// Records the options of every sign-out POST; [answer] decides how
      /// each one ends.
      List<Options?> stubSignOutPost(
        Future<Response<String>> Function() answer,
      ) {
        final sent = <Options?>[];
        when(
          () => mockDio.post<String>(
            signOutEndpoint,
            options: any(named: 'options'),
          ),
        ).thenAnswer((invocation) {
          sent.add(invocation.namedArguments[#options] as Options?);
          return answer();
        });
        return sent;
      }

      /// Every auth state the repository publishes from here on.
      List<AuthState> recordStates() {
        final states = <AuthState>[];
        final subscription = repo.watchAuthState().listen(states.add);
        addTearDown(subscription.cancel);
        return states;
      }

      Matcher deviceStorageFault() => isA<AuthDeviceStorageException>().having(
        (e) => e.cause,
        'cause',
        same(storageFault),
      );

      test('a token store failure revokes the granted session, clears, and '
          'throws AuthDeviceStorageException', () async {
        stubGrant();
        stubStoreFails();
        stubClear();
        final sent = stubSignOutPost(() async => _status(200));
        final states = recordStates();

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(deviceStorageFault()),
        );
        // The revoke is fire-and-forget; let it run.
        await pumpEventQueue();

        verify(() => mockStorage.clear()).called(1);
        expect(sent, hasLength(1), reason: 'one revoke of the granted session');
        expect(
          sent.single?.headers?['Authorization'],
          'Bearer session-tok-abc',
        );
        expect(states, isNot(contains(isA<AuthStateAuthenticated>())));
        expect(repo.currentAuthState, isNot(isA<AuthStateAuthenticated>()));
      });

      final failedRevokes = <String, Future<Response<String>> Function()>{
        'the sign-out POST answers 500': () async => _status(500),
        'the sign-out POST fails in transport': () async => throw DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(),
        ),
      };
      for (final MapEntry(key: name, value: answer) in failedRevokes.entries) {
        test('a failed revoke after a store failure still throws '
            'AuthDeviceStorageException: $name', () async {
          stubGrant();
          stubStoreFails();
          stubClear();
          final sent = stubSignOutPost(answer);

          await expectLater(
            repo.signIn(email: 'a@b.com', password: 'pass'),
            throwsA(deviceStorageFault()),
          );
          await pumpEventQueue();

          expect(sent, hasLength(1));
          verify(() => mockStorage.clear()).called(1);
        });
      }

      test('a sign-out during a failing store reports superseded, not '
          'storage', () async {
        stubGrant();
        stubClear();
        // The sign-out reads no stored token: the grant's never landed.
        when(() => mockStorage.retrieve()).thenAnswer((_) async => null);
        final sent = stubSignOutPost(() async => _status(200));
        final storeReached = Completer<void>();
        final storeGate = Completer<void>();
        when(
          () => mockStorage.store(
            token: any(named: 'token'),
            expiresAt: any(named: 'expiresAt'),
            persistedAt: any(named: 'persistedAt'),
            user: any(named: 'user'),
          ),
        ).thenAnswer((_) {
          storeReached.complete();
          return storeGate.future;
        });

        final signIn = repo.signIn(email: 'a@b.com', password: 'pass');
        await storeReached.future;
        await repo.signOut();
        storeGate.completeError(storageFault);

        await expectLater(signIn, throwsA(isA<AuthSupersededException>()));
        await pumpEventQueue();

        // The sign-out could not revoke the grant, since it never reached
        // storage, so the grant revokes itself.
        expect(
          sent.map((options) => options?.headers?['Authorization']),
          contains('Bearer session-tok-abc'),
        );
      });

      test('a sign-out during the clear after a failing store reports '
          'superseded, not storage, and logs the fault quietly', () async {
        stubGrant();
        stubStoreFails();
        when(() => mockStorage.retrieve()).thenAnswer((_) async => null);
        final sent = stubSignOutPost(() async => _status(200));
        final clearReached = Completer<void>();
        final clearGate = Completer<void>();
        when(() => mockStorage.clear()).thenAnswer((_) {
          // The grant's clear is held; the sign-out's own clear is not.
          if (clearReached.isCompleted) return Future<void>.value();
          clearReached.complete();
          return clearGate.future;
        });
        final records = <LogRecord>[];
        final previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final logs = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          await logs.cancel();
          Logger.root.level = previousLevel;
        });

        final signIn = repo.signIn(email: 'a@b.com', password: 'pass');
        await clearReached.future;
        await repo.signOut();
        clearGate.complete();

        await expectLater(signIn, throwsA(isA<AuthSupersededException>()));
        await pumpEventQueue();

        expect(
          sent.map((options) => options?.headers?['Authorization']),
          contains('Bearer session-tok-abc'),
        );
        final storageRecords = records.where(
          (record) => identical(record.error, storageFault),
        );
        expect(storageRecords, hasLength(1), reason: 'the fault is kept');
        expect(
          storageRecords.single.level,
          lessThan(Level.WARNING),
          reason: 'superseded is quiet',
        );
      });

      test('a raw storage read failure during the reconcile throws '
          'AuthDeviceStorageException', () async {
        stubGrant();
        stubStore();
        stubClear();
        when(
          () => mockStorage.retrieve(),
        ).thenAnswer((_) => Future.error(storageFault));
        final sent = stubSignOutPost(() async => _status(200));
        final states = recordStates();

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(deviceStorageFault()),
        );
        await pumpEventQueue();

        verify(() => mockStorage.clear()).called(1);
        expect(sent, hasLength(1));
        expect(
          sent.single?.headers?['Authorization'],
          'Bearer session-tok-abc',
        );
        expect(states, isNot(contains(isA<AuthStateAuthenticated>())));
        verifyNever(
          () => mockDio.get<String>(any(), options: any(named: 'options')),
        );
      });

      test('a raw reconcile failure after another read confirmed the grant '
          'leaves the repository unauthenticated', () async {
        stubGrant();
        stubStore();
        stubClear();
        when(
          () => mockDio.get<String>(
            '$testAuthBasePath/get-session',
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(_sessionJson()));
        stubSignOutPost(() async => _status(200));
        final readReached = Completer<void>();
        final readGate = Completer<StoredSession?>();
        when(() => mockStorage.retrieve()).thenAnswer((_) {
          // The reconcile's read is held, then fails; the other read finds
          // the grant's token.
          if (readReached.isCompleted) {
            return Future.value(
              StoredSession(
                token: 'session-tok-abc',
                persistedAt: DateTime.utc(2026),
              ),
            );
          }
          readReached.complete();
          return readGate.future;
        });
        final states = recordStates();

        final signIn = repo.signIn(email: 'a@b.com', password: 'pass');
        await readReached.future;
        await repo.getSession();
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
        readGate.completeError(storageFault);

        await expectLater(signIn, throwsA(deviceStorageFault()));
        await pumpEventQueue();

        // Storage is cleared and the session revoked, so a live state would
        // be a session nothing backs.
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
        expect(states.last, isA<AuthStateUnauthenticated>());
      });

      /// Fails the grant's own store, and lets every later one succeed, so a
      /// read that outlives the abandon could write its session back.
      List<int> stubOnlyGrantStoreFails() {
        final stores = <int>[];
        when(
          () => mockStorage.store(
            token: any(named: 'token'),
            expiresAt: any(named: 'expiresAt'),
            persistedAt: any(named: 'persistedAt'),
            user: any(named: 'user'),
          ),
        ).thenAnswer((_) {
          stores.add(stores.length + 1);
          return stores.length == 1
              ? Future.error(storageFault)
              : Future.value();
        });
        return stores;
      }

      /// Holds every session read's response until the returned completer
      /// completes.
      Completer<Response<String>> holdSessionReads() {
        final gate = Completer<Response<String>>();
        when(
          () => mockDio.get<String>(
            '$testAuthBasePath/get-session',
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) => gate.future);
        return gate;
      }

      test('a session read in flight when the grant is abandoned does not '
          'store or publish its session afterwards', () async {
        stubGrant();
        stubRetrieve();
        stubClear();
        stubSignOutPost(() async => _status(200));
        final stores = stubOnlyGrantStoreFails();
        final readGate = holdSessionReads();
        final states = recordStates();

        final read = repo.getSession();
        await pumpEventQueue();
        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(deviceStorageFault()),
        );
        readGate.complete(_ok(_sessionJson()));

        expect(await read, isNull);
        await pumpEventQueue();

        expect(stores, hasLength(1), reason: 'only the grant store ran');
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
        expect(states, isNot(contains(isA<AuthStateAuthenticated>())));
      });

      test(
        'a session read landing while an abandoned grant is cleared does not '
        'write its session back, and the grant still fails on storage',
        () async {
          stubGrant();
          stubRetrieve();
          stubSignOutPost(() async => _status(200));
          final stores = stubOnlyGrantStoreFails();
          final readGate = holdSessionReads();
          final clearReached = Completer<void>();
          final clearGate = Completer<void>();
          when(() => mockStorage.clear()).thenAnswer((_) {
            if (clearReached.isCompleted) return Future.value();
            clearReached.complete();
            return clearGate.future;
          });
          final states = recordStates();

          final read = repo.getSession();
          await pumpEventQueue();
          final signIn = repo.signIn(email: 'a@b.com', password: 'pass');
          await clearReached.future;
          readGate.complete(_ok(_sessionJson()));

          expect(await read, isNull);
          clearGate.complete();

          // The abandon itself is not a sign-out: the grant still reports the
          // storage fault, not supersession.
          await expectLater(signIn, throwsA(deviceStorageFault()));
          await pumpEventQueue();

          expect(stores, hasLength(1), reason: 'only the grant store ran');
          expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
          expect(states, isNot(contains(isA<AuthStateAuthenticated>())));
        },
      );

      test('a raw failure storing the confirmed session during the reconcile '
          'throws AuthDeviceStorageException', () async {
        stubGrant();
        stubRetrieve();
        stubClear();
        when(
          () => mockDio.get<String>(
            '$testAuthBasePath/get-session',
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => _ok(_sessionJson()));
        // The grant's own store lands; the reconcile's store of the session
        // the server confirmed does not.
        when(
          () => mockStorage.store(
            token: any(named: 'token'),
            expiresAt: any(named: 'expiresAt'),
            persistedAt: any(named: 'persistedAt'),
            user: any(named: 'user'),
          ),
        ).thenAnswer(
          (invocation) =>
              invocation.namedArguments[#token] == _kServerVendedToken
              ? Future.error(storageFault)
              : Future<void>.value(),
        );
        final sent = stubSignOutPost(() async => _status(200));
        final states = recordStates();

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'pass'),
          throwsA(deviceStorageFault()),
        );
        await pumpEventQueue();

        verify(() => mockStorage.clear()).called(1);
        expect(sent, hasLength(1));
        expect(
          sent.single?.headers?['Authorization'],
          'Bearer session-tok-abc',
        );
        expect(states, isNot(contains(isA<AuthStateAuthenticated>())));
      });

      test('a raw reconcile failure after a sign-out reports superseded, not '
          'storage', () async {
        stubGrant();
        stubStore();
        stubClear();
        final sent = stubSignOutPost(() async => _status(200));
        final readReached = Completer<void>();
        final readGate = Completer<StoredSession?>();
        when(() => mockStorage.retrieve()).thenAnswer((_) {
          // The reconcile's read is held, then fails; the sign-out's own read
          // of its token finds nothing.
          if (readReached.isCompleted) return Future.value();
          readReached.complete();
          return readGate.future;
        });

        final signIn = repo.signIn(email: 'a@b.com', password: 'pass');
        await readReached.future;
        await repo.signOut();
        readGate.completeError(storageFault);

        await expectLater(signIn, throwsA(isA<AuthSupersededException>()));
        await pumpEventQueue();

        expect(
          sent.map((options) => options?.headers?['Authorization']),
          contains('Bearer session-tok-abc'),
        );
        verifyNever(
          () => mockDio.get<String>(any(), options: any(named: 'options')),
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
          when(() => mockDio.get<String>(any(), options: any(named: 'options')))
              .thenAnswer((_) async => _status(401));

          expect(await repo.getSession(), isNull);
          verify(() => mockStorage.clear()).called(1);
        },
      );

      test('updates stored expiry from session response', () async {
        stubRetrieve();
        when(() => mockDio.get<String>(any(), options: any(named: 'options')))
            .thenAnswer((_) async => _ok(_sessionJson()));
        stubStore();

        await repo.getSession();

        verify(
          () => mockStorage.store(
            // The server-vended token, not the one the request carried.
            token: _kServerVendedToken,
            expiresAt: any(named: 'expiresAt'),
            persistedAt: any(named: 'persistedAt'),
            user: any(named: 'user'),
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
        when(() => mockDio.post<String>(any(), options: any(named: 'options')))
            .thenThrow(
              DioException(
                type: DioExceptionType.connectionError,
                requestOptions: RequestOptions(),
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
          identity: testServerIdentity().copyWith(strategies: []),
          serverUrl: testServerUrl,
          tokenStorage: mockStorage,
          dio: mockDio,
        );

        expect(
          () => noStrategyRepo.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<AuthServerException>()),
        );

        addTearDown(noStrategyRepo.onDispose);
      });

      group('logs the missing strategy', () {
        late List<LogRecord> records;
        late StreamSubscription<LogRecord> sub;
        late Level previousLevel;
        late AuthRepositoryImpl noStrategyRepo;

        setUp(() {
          records = [];
          previousLevel = Logger.root.level;
          Logger.root.level = Level.ALL;
          sub = Logger.root.onRecord.listen(records.add);
          noStrategyRepo = AuthRepositoryImpl(
            identity: testServerIdentity().copyWith(strategies: []),
            serverUrl: testServerUrl,
            tokenStorage: mockStorage,
            dio: mockDio,
          );
        });

        tearDown(() async {
          await sub.cancel();
          Logger.root.level = previousLevel;
          await noStrategyRepo.onDispose();
        });

        Future<void> expectLoggedOnceThenThrown(
          Future<Object?> Function() call,
        ) async {
          await expectLater(
            call,
            throwsA(
              isA<AuthServerException>().having(
                (e) => e.message,
                'message',
                'This server does not support email/password authentication.',
              ),
            ),
          );

          final logged = records
              .where(
                (r) =>
                    r.loggerName == 'bge.auth.repository' &&
                    r.level == Level.SEVERE &&
                    r.message ==
                        'Email/password strategy missing on cached identity',
              )
              .toList();
          expect(logged, hasLength(1));
          expect(LogRecordFormatter.contextOf(logged.single), {
            'base_url': 'https://bge.example.com',
            'has_strategies': false,
            'strategy_count': 0,
          });
          verifyNever(
            () => mockDio.post<String>(
              any(),
              data: any(named: 'data'),
              options: any(named: 'options'),
            ),
          );
        }

        test(
          'signIn logs the missing strategy once, redacted, then throws',
          () async {
            await expectLoggedOnceThenThrown(
              () => noStrategyRepo.signIn(email: 'a@b.com', password: 'p'),
            );
          },
        );

        test(
          'signUp logs the missing strategy once, redacted, then throws',
          () async {
            await expectLoggedOnceThenThrown(
              () => noStrategyRepo.signUp(
                email: 'a@b.com',
                password: 'p',
                username: 'u',
              ),
            );
          },
        );
      });
    });
  });
}
