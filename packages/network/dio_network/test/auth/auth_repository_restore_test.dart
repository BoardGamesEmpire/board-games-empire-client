import 'dart:async';
import 'dart:convert';

import 'package:di/di.dart' show LocalClockService;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import 'package:dio_network/src/auth/auth_repository_impl.dart';
import 'package:dio_network/src/auth/token_storage_service.dart';

class MockDio extends Mock implements Dio {}

class MockTokenStorage extends Mock implements TokenStorageService {}

const _kAuthBase = '/api/auth';

/// What the client holds before revalidating.
const _kStoredToken = 'session-tok-abc';

/// What `GET /get-session` returns — the authoritative credential, which
/// the server may have renewed since sign-in.
const _kServerVendedToken = 'session-tok-renewed';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

Map<String, dynamic> _wireUser() => {
  'id': 'user-1',
  'name': 'testuser',
  'email': 'test@example.com',
  'emailVerified': true,
  'createdAt': '2024-01-01T00:00:00.000Z',
  'updatedAt': '2024-01-01T00:00:00.000Z',
};

/// The session endpoint's payload. `session.token` is deliberately
/// DIFFERENT from the token the client had stored, so every assertion that
/// touches it proves the client adopts the server-vended credential rather
/// than echoing its own back. With both fixtures sharing one string these
/// tests passed either way and pinned nothing.
Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': _kServerVendedToken,
    'expiresAt': '2026-01-08T00:00:00.000Z',
    'userId': 'user-1',
  },
  'user': _wireUser(),
};

Response<String> _response(int code, [Map<String, dynamic>? data]) => Response(
  data: data == null ? null : jsonEncode(data),
  statusCode: code,
  requestOptions: RequestOptions(path: ''),
);

/// #98: optimistic offline session restore.
///
/// Two invariants carry the feature, and both are asserted here rather than
/// left to the bloc layer:
///
/// 1. A cold start with no connectivity can produce a session from persisted
///    material alone — the old `getCachedSession` required an in-memory
///    authenticated state, which by definition does not exist at cold start.
/// 2. `getSession` distinguishes a **definitive** negative (session gone) from
///    an **indeterminate** one (we could not ask). Collapsing the two is what
///    sent users to the sign-in form on a transient 5xx and implied their
///    session had been rejected.
void main() {
  late MockDio mockDio;
  late MockTokenStorage mockStorage;
  late AuthRepositoryImpl repo;

  // "Now" for the whole suite: inside the confirmed session window and after
  // the material was persisted.
  final now = DateTime.utc(2026, 1, 2);
  final persistedAt = DateTime.utc(2026, 1, 1);
  final confirmedExpiry = DateTime.utc(2026, 1, 8);
  final user = AuthUser.fromJson(_wireUser());

  AuthRepositoryImpl build({DateTime? clockNow, DateTime? deviceNow}) =>
      AuthRepositoryImpl(
        identity: _identity(),
        tokenStorage: mockStorage,
        dio: mockDio,
        clock: LocalClockService(() => clockNow ?? now),
        deviceNowUtc: () => deviceNow ?? clockNow ?? now,
      );

  setUp(() {
    mockDio = MockDio();
    when(() => mockDio.options)
        .thenReturn(BaseOptions(baseUrl: 'https://api.example.com'));
    mockStorage = MockTokenStorage();
    when(
      () => mockStorage.store(
        token: any(named: 'token'),
        expiresAt: any(named: 'expiresAt'),
        persistedAt: any(named: 'persistedAt'),
        user: any(named: 'user'),
      ),
    ).thenAnswer((_) async {});
    when(() => mockStorage.clear()).thenAnswer((_) async {});
    repo = build();
  });

  tearDown(() async => repo.onDispose());

  void stubRetrieve(StoredSession? session) =>
      when(() => mockStorage.retrieve()).thenAnswer((_) async => session);

  StoredSession restorable() => StoredSession(
    token: _kStoredToken,
    persistedAt: persistedAt,
    expiresAt: confirmedExpiry,
    user: user,
  );

  group('getCachedSession() at cold start', () {
    test('returns the persisted session with no in-memory state — the '
        'hole #98 exists to close', () async {
      stubRetrieve(restorable());

      // Cold start: nothing has run yet.
      expect(repo.currentAuthState, isA<AuthStateUnknown>());

      final cached = await repo.getCachedSession();

      expect(cached, isNotNull);
      expect(cached!.token, _kStoredToken);
      expect(cached.user.id, 'user-1');
      expect(cached.expiresAt, confirmedExpiry);
      verifyNever(() => mockDio.get<String>(any()));
    });

    test('is a pure read — it does not adopt the session as state', () async {
      stubRetrieve(restorable());

      await repo.getCachedSession();

      expect(repo.currentAuthState, isA<AuthStateUnknown>());
    });

    test('returns null when nothing is stored', () async {
      stubRetrieve(null);
      expect(await repo.getCachedSession(), isNull);
    });

    test('returns null when the expiry was never server-confirmed', () async {
      stubRetrieve(
        StoredSession(
          token: _kStoredToken,
          persistedAt: persistedAt,
          user: user,
        ),
      );

      expect(await repo.getCachedSession(), isNull);
    });

    test('returns null without a user snapshot', () async {
      stubRetrieve(
        StoredSession(
          token: _kStoredToken,
          persistedAt: persistedAt,
          expiresAt: confirmedExpiry,
        ),
      );

      expect(await repo.getCachedSession(), isNull);
    });

    test('returns null when the confirmed expiry has passed', () async {
      final late = build(clockNow: DateTime.utc(2026, 2, 1));
      addTearDown(late.onDispose);
      stubRetrieve(restorable());

      expect(await late.getCachedSession(), isNull);
    });

    test('returns null when the local clock precedes the write — a clock '
        'this wrong cannot adjudicate expiry either way', () async {
      final backwards = build(clockNow: DateTime.utc(2025, 12, 1));
      addTearDown(backwards.onDispose);
      stubRetrieve(restorable());

      expect(await backwards.getCachedSession(), isNull);
    });
  });

  group('getCachedSession() while signed in', () {
    test(
      'prefers the in-memory session even when the persisted expiry was '
      'never confirmed — a signed-in caller is never told otherwise',
      () async {
        // Reach an authenticated state whose reconcile could not complete, so
        // the persisted expiry stays unknown.
        stubRetrieve(
          StoredSession(
            token: _kStoredToken,
            persistedAt: persistedAt,
            user: user,
          ),
        );
        when(() => mockDio.post<String>(any(), data: any(named: 'data')))
            .thenAnswer(
              (_) async =>
                  _response(200, {'token': _kStoredToken, 'user': _wireUser()}),
            );
        when(() => mockDio.get<String>(any())).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        await repo.signIn(email: 'a@b.com', password: 'p');
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());

        final cached = await repo.getCachedSession();

        expect(cached, isNotNull);
        expect(cached!.token, _kStoredToken);
      },
    );

    test(
      'returns null for known-dead material even with an authenticated '
      'in-memory session — the short-circuit must not outrank expiry',
      () async {
        // Establish a real in-memory session first; without this the assertion
        // below passes for the wrong reason (no in-memory branch to bypass).
        stubRetrieve(restorable());
        when(() => mockDio.get<String>('$_kAuthBase/get-session'))
            .thenAnswer((_) async => _response(200, _sessionJson()));
        await repo.getSession();
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
        expect(await repo.getCachedSession(), isNotNull);

        // Same repository, same in-memory session — but time has moved past
        // the confirmed expiry.
        final expired = AuthRepositoryImpl(
          identity: _identity(),
          tokenStorage: mockStorage,
          dio: mockDio,
          clock: LocalClockService(() => DateTime.utc(2026, 2, 1)),
          deviceNowUtc: () => DateTime.utc(2026, 2, 1),
        );
        addTearDown(expired.onDispose);
        await expired.getSession();
        expect(expired.currentAuthState, isA<AuthStateAuthenticated>());

        when(() => mockDio.get<String>(any()))
            .thenAnswer((_) async => _response(503));
        stubRetrieve(restorable());

        expect(await expired.getCachedSession(), isNull);
      },
    );
  });

  group('restoreCachedSession()', () {
    test(
      'adopts the cached session as unverifiedOffline and notifies '
      'watchers — user-scoped repos resolve the user from here (#128)',
      () async {
        stubRetrieve(restorable());

        final emissions = <AuthState>[];
        final sub = repo.watchAuthState().listen(emissions.add);
        await pumpEventQueue();

        final restored = await repo.restoreCachedSession();
        await pumpEventQueue();
        await sub.cancel();

        expect(restored, isNotNull);
        expect(
          repo.currentAuthState,
          AuthStateAuthenticated(
            session: restored!,
            verification: SessionVerification.unverifiedOffline,
          ),
        );
        expect(emissions.last, isA<AuthStateAuthenticated>());
        expect(
          (emissions.last as AuthStateAuthenticated).verification,
          SessionVerification.unverifiedOffline,
        );
      },
    );

    test('an unverified state is NOT equal to the verified state for the '
        'same session — otherwise a successful revalidation would be '
        'invisible downstream', () async {
      stubRetrieve(restorable());
      final restored = (await repo.restoreCachedSession())!;

      expect(
        AuthStateAuthenticated(
          session: restored,
          verification: SessionVerification.unverifiedOffline,
        ),
        isNot(AuthStateAuthenticated(session: restored)),
      );
    });

    test('returns null and leaves the state untouched when no cached '
        'session qualifies', () async {
      stubRetrieve(null);

      expect(await repo.restoreCachedSession(), isNull);
      expect(repo.currentAuthState, isA<AuthStateUnknown>());
    });

    test('does not downgrade an already server-verified session', () async {
      stubRetrieve(restorable());
      when(() => mockDio.get<String>('$_kAuthBase/get-session'))
          .thenAnswer((_) async => _response(200, _sessionJson()));

      await repo.getSession();
      expect(
        (repo.currentAuthState as AuthStateAuthenticated).verification,
        SessionVerification.verified,
      );

      await repo.restoreCachedSession();

      expect(
        (repo.currentAuthState as AuthStateAuthenticated).verification,
        SessionVerification.verified,
      );
    });
  });

  group('getSession() definitive vs indeterminate', () {
    test('a 5xx THROWS rather than returning null — a transient server '
        'fault must not read as "your session was rejected"', () async {
      stubRetrieve(restorable());
      when(() => mockDio.get<String>(any()))
          .thenAnswer((_) async => _response(503));

      await expectLater(
        repo.getSession(),
        throwsA(
          isA<AuthServerException>().having((e) => e.statusCode, 'status', 503),
        ),
      );
      // Indeterminate must never destroy material we may still need.
      verifyNever(() => mockStorage.clear());
      expect(repo.currentAuthState, isA<AuthStateUnknown>());
    });

    test('BetterAuth\'s 200-with-null-body is a definitive "no session": '
        'clears material and settles unauthenticated', () async {
      stubRetrieve(restorable());
      when(() => mockDio.get<String>(any()))
          .thenAnswer((_) async => _response(200));

      expect(await repo.getSession(), isNull);
      verify(() => mockStorage.clear()).called(1);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a 403 is a definitive credential rejection, not indeterminate: '
        'clears material and settles unauthenticated rather than stranding '
        'the user on a retry-forever view', () async {
      stubRetrieve(restorable());
      when(() => mockDio.get<String>(any()))
          .thenAnswer((_) async => _response(403));

      expect(await repo.getSession(), isNull);
      verify(() => mockStorage.clear()).called(1);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a session response resolving AFTER sign-out is discarded — it must '
        'not rewrite the token, re-persist the user snapshot, or re-emit '
        'authenticated', () async {
      stubRetrieve(restorable());
      when(() => mockDio.post<String>(any(), options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response<String>(
              statusCode: 200,
              requestOptions: RequestOptions(path: ''),
            ),
          );

      // Hold the session response open, sign out, then let it land.
      final gate = Completer<Response<String>>();
      when(() => mockDio.get<String>('$_kAuthBase/get-session'))
          .thenAnswer((_) => gate.future);

      final inFlight = repo.getSession();
      await repo.signOut();
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());

      gate.complete(_response(200, _sessionJson()));
      expect(await inFlight, isNull);
      await pumpEventQueue();

      // Sign-out stays total: no rewrite of the credential, and — the part
      // #98 makes load-bearing — no PII snapshot back on disk.
      verifyNever(
        () => mockStorage.store(
          token: any(named: 'token'),
          expiresAt: any(named: 'expiresAt'),
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      );
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('adopts the SERVER-VENDED token, replacing the one it sent — a '
        'renewed credential must not be echoed away, or the client 401s '
        'about one refresh interval after sign-in', () async {
      stubRetrieve(restorable());
      when(() => mockDio.get<String>('$_kAuthBase/get-session'))
          .thenAnswer((_) async => _response(200, _sessionJson()));

      final session = await repo.getSession();

      expect(session!.token, _kServerVendedToken);
      expect(
        (repo.currentAuthState as AuthStateAuthenticated).session.token,
        _kServerVendedToken,
        reason: 'in-memory state and stored payload must agree',
      );
      verify(
        () => mockStorage.store(
          token: _kServerVendedToken,
          expiresAt: any(named: 'expiresAt'),
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      ).called(1);
    });

    test('a sign-out landing DURING the success-path store is not undone: '
        'the write that lifted the latch is re-cleared and no authenticated '
        'state is emitted', () async {
      stubRetrieve(restorable());
      when(() => mockDio.post<String>(any(), options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response<String>(
              statusCode: 200,
              requestOptions: RequestOptions(path: ''),
            ),
          );
      when(() => mockDio.get<String>('$_kAuthBase/get-session'))
          .thenAnswer((_) async => _response(200, _sessionJson()));

      // The store await is the race window: sign out from INSIDE it.
      when(
        () => mockStorage.store(
          token: any(named: 'token'),
          expiresAt: any(named: 'expiresAt'),
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      ).thenAnswer((_) async {
        await repo.signOut();
      });

      expect(await repo.getSession(), isNull);

      // Our own store lifted the sign-out latch; it must be re-cleared —
      // once by signOut, once by the undo — or the PII snapshot survives.
      verify(() => mockStorage.clear()).called(2);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('persists the server-confirmed expiry and user snapshot — the only '
        'path that makes a later offline restore possible', () async {
      stubRetrieve(restorable());
      when(() => mockDio.get<String>('$_kAuthBase/get-session'))
          .thenAnswer((_) async => _response(200, _sessionJson()));

      // Read the persisted arguments by name rather than through several
      // captureAny matchers: mocktail appends multi-argument captures in the
      // invocation's own named-argument order, which is not the order they
      // are written in the verify call, so positional indexing into
      // `captured` silently pairs assertions with the wrong values. Same
      // technique as the sign-out suite's `namedArguments[#options]` read.
      String? persistedToken;
      DateTime? persistedExpiry;
      DateTime? persistedStamp;
      AuthUser? persistedUser;
      when(
        () => mockStorage.store(
          token: any(named: 'token'),
          expiresAt: any(named: 'expiresAt'),
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      ).thenAnswer((invocation) async {
        persistedToken = invocation.namedArguments[#token] as String?;
        persistedExpiry = invocation.namedArguments[#expiresAt] as DateTime?;
        persistedStamp = invocation.namedArguments[#persistedAt] as DateTime?;
        persistedUser = invocation.namedArguments[#user] as AuthUser?;
      });

      await repo.getSession();

      expect(
        persistedToken,
        _kServerVendedToken,
        reason: 'the server-vended credential, not the one we sent',
      );
      expect(
        persistedExpiry,
        DateTime.utc(2026, 1, 8),
        reason: 'the server-confirmed expiry, not a client estimate',
      );
      expect(persistedStamp, now, reason: 'stamped from the per-server clock');
      expect(persistedUser?.id, 'user-1');
    });
  });

  group('credential grant reconcile', () {
    void stubSignInOk() =>
        when(
          () => mockDio.post<String>(
            '$_kAuthBase/sign-in/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer(
          (_) async =>
              _response(200, {'token': _kStoredToken, 'user': _wireUser()}),
        );

    test('persists the snapshot with an UNKNOWN expiry before reconciling '
        '— the client never invents a session lifetime', () async {
      stubSignInOk();
      stubRetrieve(
        StoredSession(
          token: _kStoredToken,
          persistedAt: persistedAt,
          user: user,
        ),
      );
      when(() => mockDio.get<String>('$_kAuthBase/get-session'))
          .thenAnswer((_) async => _response(200, _sessionJson()));

      await repo.signIn(email: 'a@b.com', password: 'p');

      // The GRANT store carries the grant's own token with a null expiry;
      // the reconcile that follows overwrites it with the server-vended
      // credential (asserted separately above).
      verify(
        () => mockStorage.store(
          token: _kStoredToken,
          expiresAt: null,
          persistedAt: now,
          user: any(named: 'user', that: isNotNull),
        ),
      ).called(1);
    });

    test('an INDETERMINATE reconcile keeps the granted session — the '
        'sign-in genuinely succeeded and must not report failure', () async {
      stubSignInOk();
      stubRetrieve(
        StoredSession(
          token: _kStoredToken,
          persistedAt: persistedAt,
          user: user,
        ),
      );
      when(() => mockDio.get<String>(any())).thenThrow(
        DioException(
          type: DioExceptionType.connectionError,
          requestOptions: RequestOptions(path: ''),
        ),
      );

      final session = await repo.signIn(email: 'a@b.com', password: 'p');

      expect(
        session.token,
        _kStoredToken,
        reason: 'the grant token survives when no reconcile confirmed one',
      );
      expect(session.expiresAt, isNull, reason: 'expiry stays unconfirmed');
      expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
      expect(
        (repo.currentAuthState as AuthStateAuthenticated).verification,
        SessionVerification.verified,
        reason: 'the grant itself was a server round trip',
      );
    });

    test('a sign-out during the grant STORE window throws '
        'AuthSupersededException, re-clears, and never reports a server '
        'fault (#146)', () async {
      stubSignInOk();
      when(() => mockDio.post<String>(any(), options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response<String>(
              statusCode: 200,
              requestOptions: RequestOptions(path: ''),
            ),
          );
      stubRetrieve(
        StoredSession(
          token: _kStoredToken,
          persistedAt: persistedAt,
          user: user,
        ),
      );
      when(
        () => mockStorage.store(
          token: any(named: 'token'),
          expiresAt: any(named: 'expiresAt'),
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      ).thenAnswer((_) async {
        await repo.signOut();
      });

      await expectLater(
        repo.signIn(email: 'a@b.com', password: 'p'),
        throwsA(isA<AuthSupersededException>()),
      );
      verify(() => mockStorage.clear()).called(2);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a sign-out during the grant RECONCILE window throws '
        'AuthSupersededException, not the contract-violation '
        'AuthServerException (#146)', () async {
      stubSignInOk();
      when(() => mockDio.post<String>(any(), options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response<String>(
              statusCode: 200,
              requestOptions: RequestOptions(path: ''),
            ),
          );
      stubRetrieve(
        StoredSession(
          token: _kStoredToken,
          persistedAt: persistedAt,
          user: user,
        ),
      );

      // Hold the reconcile open, sign out, then let it land.
      final gate = Completer<Response<String>>();
      when(() => mockDio.get<String>('$_kAuthBase/get-session'))
          .thenAnswer((_) => gate.future);

      final inFlight = repo.signIn(email: 'a@b.com', password: 'p');
      await pumpEventQueue();
      await repo.signOut();
      gate.complete(_response(200, _sessionJson()));

      await expectLater(inFlight, throwsA(isA<AuthSupersededException>()));
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a DEFINITIVE "no session" after a successful grant throws — the '
        'token has already been cleared, so reporting success would 401 on '
        'every later request', () async {
      stubSignInOk();
      stubRetrieve(
        StoredSession(
          token: _kStoredToken,
          persistedAt: persistedAt,
          user: user,
        ),
      );
      when(() => mockDio.get<String>(any()))
          .thenAnswer((_) async => _response(401));

      await expectLater(
        repo.signIn(email: 'a@b.com', password: 'p'),
        throwsA(isA<AuthServerException>()),
      );
    });
  });
}
