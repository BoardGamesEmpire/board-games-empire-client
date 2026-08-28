import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart' show AuthResponse;

import 'package:web_network/src/auth/web_auth_repository_impl.dart';

class MockDio extends Mock implements Dio {}

// Endpoints are relative paths resolved against the browser origin by the
// per-server Dio (set via WebDioFactory). The repository passes them through to
// Dio unchanged.
const _kAuthBase = '/api/auth';

ServerIdentity _identity({bool signUpDisabled = false}) => ServerIdentity(
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
    EmailAndPasswordStrategy(
      signUpDisabled: signUpDisabled,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: signUpDisabled ? null : '$_kAuthBase/sign-up/email',
    ),
  ],
);

// BetterAuth wire shape: camelCase fields, display name under `name`
// (mapped to AuthUser.username).
Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': 'session-tok-web',
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': 'user-1',
  },
  'user': {
    'id': 'user-1',
    'name': 'webuser',
    'email': 'web@example.com',
    'emailVerified': true,
    'createdAt': '2024-01-01T00:00:00.000Z',
    'updatedAt': '2024-01-01T00:00:00.000Z',
  },
};

// BetterAuth sign-in / sign-up grant envelope: a token and a user, but no
// expiry — that only arrives from the session endpoint. Web never uses this
// token as a credential (the browser holds the httpOnly cookie); it is the
// user identity that makes a granted session adoptable.
Map<String, dynamic> _grantJson() => {
  'token': 'grant-tok-web',
  'user': {
    'id': 'user-1',
    'name': 'webuser',
    'email': 'web@example.com',
    'emailVerified': true,
    'createdAt': '2024-01-01T00:00:00.000Z',
    'updatedAt': '2024-01-01T00:00:00.000Z',
  },
};

Response<Map<String, dynamic>> _ok(Map<String, dynamic> data) => Response(
  data: data,
  statusCode: 200,
  requestOptions: RequestOptions(path: ''),
);

Response<Map<String, dynamic>> _status(
  int code, [
  Map<String, dynamic>? data,
]) => Response(
  data: data,
  statusCode: code,
  requestOptions: RequestOptions(path: ''),
);

void main() {
  late MockDio mockDio;
  late WebAuthRepositoryImpl repo;

  setUp(() {
    mockDio = MockDio();
    repo = WebAuthRepositoryImpl(identity: _identity(), dio: mockDio);
  });

  tearDown(() async => repo.onDispose());

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
          ).thenAnswer((_) async => _ok(_grantJson()));

          when(
            () => mockDio.get<Map<String, dynamic>>('$_kAuthBase/get-session'),
          ).thenAnswer((_) async => _ok(_sessionJson()));

          final result = await repo.signIn(email: 'a@b.com', password: 'pass');

          // #291: web returns no token. The browser holds the httpOnly
          // cookie; the server-vended token used to be carried here for
          // shape parity, which put a live credential in Dart-reachable
          // memory that nothing read.
          expect(result.token, isNull);
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
          ).thenAnswer((_) async => _ok(_grantJson()));

          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _status(401));

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

          await disabledRepo.onDispose();
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
      test('returns AuthResponse with user, and no token, on 200', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        final result = await repo.getSession();

        // #291: the session endpoint vends the real bearer token in
        // `session.token`, and this repository deliberately drops it. Web
        // authenticates with the browser's httpOnly cookie, so retaining
        // the credential here only widened what a log or a feedback report
        // could carry off the device.
        expect(result?.token, isNull);
        expect(result?.user.username, 'webuser');
      });

      test('does not retain the token the session endpoint vended', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        final result = await repo.getSession();

        // The state emitted to every `watchAuthState` subscriber is the
        // long-lived holder — it is what makes retention a problem rather
        // than a transient parse.
        final state = repo.currentAuthState;
        expect(state, isA<AuthStateAuthenticated>());
        expect((state as AuthStateAuthenticated).session.token, isNull);
        expect(result.toString(), isNot(contains('session-tok-web')));
      });

      test('returns null and emits unauthenticated on 401', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(401));

        final future = expectLater(
          repo.watchAuthState().take(2),
          emitsInOrder([
            isA<AuthStateUnknown>(),
            isA<AuthStateUnauthenticated>(),
          ]),
        );

        expect(await repo.getSession(), isNull);
        await future;
      });

      test('emits AuthStateAuthenticated on success', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        final future = expectLater(
          repo.watchAuthState().take(2),
          emitsInOrder([
            isA<AuthStateUnknown>(),
            isA<AuthStateAuthenticated>(),
          ]),
        );

        await repo.getSession();
        await future;
      });
    });

    // Native's matrix for the same contract lives in
    // dio_network/test/auth/auth_repository_restore_test.dart under
    // "getSession() definitive vs indeterminate"; these mirror it (#180).
    //
    // What makes every case below reachable at all: WebDioFactory sets
    // `validateStatus: (_) => true`, so EVERY status — 401, 403, 5xx —
    // resolves as a normal Response rather than throwing. A test that
    // stubs a DioException for these is testing a path production never
    // takes.
    group('getSession() definitive vs indeterminate', () {
      test('a 5xx THROWS rather than returning null — a transient server '
          'fault must not read as a definitive "no session" (#98)', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(503, {'error': 'unavailable'}));

        await expectLater(
          repo.getSession(),
          throwsA(isA<AuthServerException>()),
        );
        expect(repo.currentAuthState, isA<AuthStateUnknown>());
      });

      test('a non-2xx with an EMPTY body throws: the null-body check must '
          'not outrank the status check, or a bodiless 502 signs the user '
          'out for a proxy hiccup', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(502));

        final states = <AuthState>[];
        final sub = repo.watchAuthState().listen(states.add);

        await expectLater(
          repo.getSession(),
          throwsA(isA<AuthServerException>()),
        );

        await pumpEventQueue();
        await sub.cancel();
        expect(states.whereType<AuthStateUnauthenticated>(), isEmpty);
      });

      test(
        'a 403 is a definitive credential rejection, not indeterminate: '
        'returns null so a revoked session cannot loop the retry view',
        () async {
          // Deliberately WITH a body: a bodiless 403 was already handled by
          // the old null-body clause, so an empty one would not have caught
          // the regression this pins.
          when(
            () => mockDio.get<Map<String, dynamic>>(any()),
          ).thenAnswer((_) async => _status(403, {'error': 'session revoked'}));

          expect(await repo.getSession(), isNull);
          expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
        },
      );

      test('BetterAuth\'s 200-with-null-body is a definitive "no session": '
          'returns null and emits unauthenticated', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(200));

        expect(await repo.getSession(), isNull);
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
      });

      test('a 204 — a 2xx that is not the documented 200 shape — is '
          'indeterminate and throws', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(204));

        await expectLater(
          repo.getSession(),
          throwsA(isA<AuthServerException>()),
        );
      });

      test(
        'a 200 whose body is not the documented session shape is a '
        'server fault, not a raw parse error escaping the contract',
        () async {
          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _status(200, {'unexpected': 'shape'}));

          // AuthRepository admits only AuthException subtypes out of
          // getSession. A bare CheckedFromJsonException here would slip past
          // every `on AuthException` handler in AuthBloc and strand the form
          // on AuthLoading.
          await expectLater(
            repo.getSession(),
            throwsA(isA<AuthServerException>()),
          );
        },
      );

      test('a transport failure is indeterminate: AuthNetworkException, '
          'not a sign-out', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any())).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        await expectLater(
          repo.getSession(),
          throwsA(isA<AuthNetworkException>()),
        );
        expect(repo.currentAuthState, isA<AuthStateUnknown>());
      });
    });

    // Mirrors native's "credential grant reconcile" group. Web has no token
    // storage, so the grant is never persisted — but it still carries the
    // user identity, which is what makes an unconfirmed session adoptable
    // (the browser already holds the cookie that authorises it).
    group('credential grant reconcile', () {
      setUp(() {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-in/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _ok(_grantJson()));
      });

      test('an INDETERMINATE reconcile keeps the granted session — the '
          'credential grant genuinely succeeded, and failing here would '
          'show "connection failed" for a sign-in that worked', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(503, {'error': 'unavailable'}));

        final result = await repo.signIn(email: 'a@b.com', password: 'p');

        expect(result.user.id, 'user-1');
        expect(result.expiresAt, isNull, reason: 'expiry is unconfirmed');
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
      });

      // #291: the grant envelope carries the same real token the session
      // endpoint does, so this is the SECOND producer of a token-bearing
      // AuthResponse on web — and the only one whose object survives, since
      // this branch is where a granted session is adopted and emitted.
      // Dropping the token in getSession alone would have left it here.
      test('the kept grant carries no token either', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(503, {'error': 'unavailable'}));

        final result = await repo.signIn(email: 'a@b.com', password: 'p');

        expect(result.token, isNull);
        expect(result.toString(), isNot(contains('grant-tok-web')));
        expect(
          (repo.currentAuthState as AuthStateAuthenticated).session.token,
          isNull,
        );
      });

      test('a transport failure during the reconcile also keeps the granted '
          'session', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any())).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        final result = await repo.signIn(email: 'a@b.com', password: 'p');

        expect(result.user.id, 'user-1');
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
      });

      test('a DEFINITIVE "no session" after a successful grant throws — the '
          'server accepted the credential and then disowned the session, '
          'which is a contract violation, not a network condition', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(401));

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<AuthServerException>()),
        );
      });

      test('a sign-out during the RECONCILE window throws '
          'AuthSupersededException, not a server fault (#146)', () async {
        when(() => mockDio.post<void>('$_kAuthBase/sign-out')).thenAnswer(
          (_) async => Response<void>(
            statusCode: 200,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        // A sign-out lands while the reconcile GET is in flight; the
        // response that follows describes a session the user just ended.
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async {
              await repo.signOut();
              return _ok(_sessionJson());
            });

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<AuthSupersededException>()),
        );
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
      });

      test('an unreadable session body is indeterminate, so the reconcile '
          'keeps the granted session rather than failing a sign-in whose '
          'credentials the server accepted', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(200, {'unexpected': 'shape'}));

        // The value of the getSession-side guard is that this arrives as an
        // AuthException at all: a bare parse error would escape the
        // `on AuthException` catch below, leave signIn throwing something
        // AuthBloc has no clause for, and strand the form on AuthLoading.
        final result = await repo.signIn(email: 'a@b.com', password: 'p');

        expect(result.user.id, 'user-1');
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
      });

      // The grant envelope is a FALLBACK for an indeterminate reconcile, not
      // a credential and not a precondition: on the happy path the confirmed
      // session is returned and the grant is discarded unread. So an
      // unreadable grant must not veto a sign-in the session endpoint is
      // willing to confirm — the browser already holds the cookie that
      // proves the credential was accepted.
      test(
        'a grant response with no body does not fail the sign-in — the '
        'reconcile is the authority, and the cookie is already set',
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              '$_kAuthBase/sign-in/email',
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _status(200));
          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _ok(_sessionJson()));

          final result = await repo.signIn(email: 'a@b.com', password: 'p');

          expect(result.user.id, 'user-1');
          expect(result.expiresAt, isNotNull);
          expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
        },
      );

      // BetterAuth's documented shape when email verification is required or
      // `autoSignIn` is off. On web it does not fail the sign-in, because
      // nothing here uses that token as a credential — the session endpoint
      // is the authority, and it confirms this one.
      //
      // This used to hold by accident: `AuthResponse.token` was
      // `required String`, so the envelope could not be parsed and
      // `_grantOrNull` returned null via its catch. #291 made the field
      // nullable, which would have made the envelope parse cleanly and
      // become an *adoptable* grant — signing in a user the server had
      // explicitly declined to grant a session to. `_grantOrNull` now
      // rejects it deliberately; the test below pins that.
      test(
        "BetterAuth's token:null envelope does not fail the sign-in",
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              '$_kAuthBase/sign-in/email',
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _ok({..._grantJson(), 'token': null}));
          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _ok(_sessionJson()));

          final result = await repo.signIn(email: 'a@b.com', password: 'p');

          expect(result.user.id, 'user-1');
          expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
        },
      );

      // The other half of the same shape, and the one that would regress
      // silently: a server that granted no session AND a reconcile that
      // cannot confirm one. There is nothing adoptable on either side, so
      // the reconcile's own failure must surface. If `_grantOrNull` ever
      // starts treating a token:null envelope as readable, this adopts a
      // session for a user who was never signed in, and only this test
      // says so.
      test(
        "BetterAuth's token:null envelope is not an adoptable grant",
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              '$_kAuthBase/sign-in/email',
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _ok({..._grantJson(), 'token': null}));
          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _status(503, {'error': 'unavailable'}));

          await expectLater(
            repo.signIn(email: 'a@b.com', password: 'p'),
            throwsA(isA<AuthServerException>()),
          );
          expect(repo.currentAuthState, isNot(isA<AuthStateAuthenticated>()));
        },
      );

      // Both sides failed: no readable grant to fall back on and no
      // confirmation. Nothing adoptable exists, so the reconcile's own
      // failure is what surfaces — a session synthesised here would carry no
      // real user.id and could not activate the per-(server, user) scope
      // (#135).
      test('an unreadable grant AND an indeterminate reconcile surfaces the '
          "reconcile's own failure", () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-in/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _status(200));
        when(() => mockDio.get<Map<String, dynamic>>(any())).thenThrow(
          DioException(
            type: DioExceptionType.connectionError,
            requestOptions: RequestOptions(path: ''),
          ),
        );

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<AuthNetworkException>()),
        );
      });

      // Findings that only bite through an injected Dio or a caller-supplied
      // interceptor: a 401 that arrives THROWN rather than resolved is the
      // same definitive rejection as a 401 Response, and must not be
      // bucketed as indeterminate and kept.
      test('a definitive rejection that surfaces as a thrown 401 is not kept '
          'as an indeterminate reconcile', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any())).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: ''),
            response: Response(
              statusCode: 401,
              requestOptions: RequestOptions(path: ''),
            ),
          ),
        );

        await expectLater(
          repo.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<AuthServerException>()),
        );
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
      });
    });

    // signUp routes through the same _grantOrNull + _reconcileCredentialGrant
    // pair as signIn. Covered separately because the group above stubs only
    // the sign-in endpoint, so nothing there exercises this path.
    group('credential grant reconcile (signUp)', () {
      Future<AuthResponse> register() =>
          repo.signUp(email: 'a@b.com', password: 'p', username: 'u');

      late List<LogRecord> records;
      late StreamSubscription<LogRecord> sub;
      late Level previousLevel;

      setUp(() {
        records = [];
        previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        sub = Logger.root.onRecord.listen(records.add);
      });

      tearDown(() async {
        await sub.cancel();
        Logger.root.level = previousLevel;
      });

      // The log line is the only surface these two failures have: both
      // deliberately let the sign-up succeed, so a caller sees nothing. A
      // message naming the wrong flow makes the one available signal
      // misleading.
      test(
        'names the sign-up in the no-body warning, never the sign-in',
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              '$_kAuthBase/sign-up/email',
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _status(200));
          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _ok(_sessionJson()));

          await register();

          final warning = records.singleWhere(
            (r) => r.message.contains('No body on a successful'),
          );
          expect(warning.message, contains('sign-up'));
          expect(warning.message, isNot(contains('sign-in')));
        },
      );

      test('names the sign-up in the unreadable-envelope warning', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-up/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer(
          (_) async => _ok({'token': 'tok', 'user': 'not-an-object'}),
        );
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        await register();

        final warning = records.singleWhere(
          (r) => r.message.contains('envelope'),
        );
        expect(warning.message, contains('sign-up'));
        expect(warning.message, isNot(contains('sign-in')));
      });

      // The two null-returning branches are told apart ONLY by their log
      // line, so misfiling one costs the whole signal. A body missing its
      // `token` key is not the same event as a server that answered
      // `token: null`: the first is a broken envelope worth a stack trace,
      // the second is a documented, routine outcome.
      //
      // The fixture above keeps a `token` key, so it cannot catch a
      // no-session check that runs ahead of the parse — this one has no
      // token key AND no readable user.
      test('an unparseable body with no token key is unreadable, not '
          '"no session granted"', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-up/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _ok({'user': 'not-an-object'}));
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        await register();

        final warning = records.singleWhere(
          (r) => r.message.contains('Unreadable'),
        );
        expect(
          warning.error,
          isNotNull,
          reason: 'the parse failure is the diagnostic; it must survive',
        );
        expect(warning.stackTrace, isNotNull);
        expect(
          records.where((r) => r.message.contains('No session granted')),
          isEmpty,
        );
      });

      // The converse, so the two stay distinguishable from both sides: a
      // well-formed envelope the server deliberately granted no session on
      // is routine, and must not be dressed up as a server fault.
      test('a well-formed token:null envelope is "no session granted", not '
          'unreadable', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-up/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _ok({..._grantJson(), 'token': null}));
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        await register();

        final warning = records.singleWhere(
          (r) => r.message.contains('No session granted'),
        );
        expect(warning.message, contains('sign-up'));
        expect(
          warning.error,
          isNull,
          reason: 'nothing failed — the server answered as documented',
        );
        expect(records.where((r) => r.message.contains('Unreadable')), isEmpty);
      });

      test('a grant response with no body does not fail the sign-up', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-up/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _status(200));
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        expect((await register()).user.id, 'user-1');
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
      });

      test(
        "BetterAuth's token:null envelope — the documented shape when "
        'email verification is required — does not fail the sign-up',
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              '$_kAuthBase/sign-up/email',
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _ok({..._grantJson(), 'token': null}));
          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _ok(_sessionJson()));

          expect((await register()).user.id, 'user-1');
        },
      );

      test('an INDETERMINATE reconcile keeps the granted session', () async {
        when(
          () => mockDio.post<Map<String, dynamic>>(
            '$_kAuthBase/sign-up/email',
            data: any(named: 'data'),
          ),
        ).thenAnswer((_) async => _ok(_grantJson()));
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _status(503, {'error': 'unavailable'}));

        final result = await register();

        expect(result.user.id, 'user-1');
        expect(result.expiresAt, isNull, reason: 'expiry is unconfirmed');
        expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
      });

      test(
        'a DEFINITIVE "no session" after a successful grant throws',
        () async {
          when(
            () => mockDio.post<Map<String, dynamic>>(
              '$_kAuthBase/sign-up/email',
              data: any(named: 'data'),
            ),
          ).thenAnswer((_) async => _ok(_grantJson()));
          when(() => mockDio.get<Map<String, dynamic>>(any()))
              .thenAnswer((_) async => _status(401));

          await expectLater(register(), throwsA(isA<AuthServerException>()));
        },
      );
    });

    // A 401 normally resolves as a Response (validateStatus:(_)=>true), but
    // the repository takes any injected Dio and honours caller-supplied
    // interceptors, so it can also arrive thrown. Same definitive negative,
    // so it has to settle the same way: throwing it left _currentState at
    // AuthStateUnknown while AuthBloc had already routed to the form, and
    // watchAuthState then replayed "unknown" to every later subscriber.
    group('getSession() when a rejection arrives thrown', () {
      setUp(() {
        when(() => mockDio.get<Map<String, dynamic>>(any())).thenThrow(
          DioException(
            requestOptions: RequestOptions(path: ''),
            response: Response(
              statusCode: 401,
              requestOptions: RequestOptions(path: ''),
            ),
          ),
        );
      });

      test('returns null rather than throwing', () async {
        expect(await repo.getSession(), isNull);
      });

      test('settles the repository state, so watchAuthState cannot go on '
          'replaying AuthStateUnknown', () async {
        await repo.getSession();

        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
        expect(
          await repo.watchAuthState().first,
          const AuthStateUnauthenticated(),
        );
      });
    });

    group('getCachedSession()', () {
      test('delegates to getSession() — always makes a network call', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

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

        final future = expectLater(
          repo.watchAuthState().take(2),
          emitsInOrder([
            isA<AuthStateUnknown>(),
            isA<AuthStateUnauthenticated>(),
          ]),
        );

        await repo.signOut();
        await future;
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

    // Pins the premise that bounds `_reconcileCredentialGrant`'s success
    // path. That branch does not recheck the epoch, which is only safe
    // because no subscriber can observe an emission and call signOut()
    // before an awaiting caller resumes. `_stateController` is `sync: true`,
    // but [watchAuthState] bridges it through a `Stream.multi` whose
    // delivery is asynchronous, so the synchrony never escapes the class.
    //
    // If this test ever fails, the success path has acquired a real
    // supersession window and needs the guard its failure branches have.
    group('watchAuthState() delivery ordering', () {
      test('subscribers are notified AFTER an awaiting caller resumes, which '
          'is what makes the reconcile success path safe without a '
          'recheck', () async {
        when(() => mockDio.get<Map<String, dynamic>>(any()))
            .thenAnswer((_) async => _ok(_sessionJson()));

        final order = <String>[];
        final sub = repo.watchAuthState().listen((state) {
          if (state is AuthStateAuthenticated) order.add('subscriber');
        });
        addTearDown(sub.cancel);

        await repo.getSession().then((_) => order.add('awaiting-caller'));
        await pumpEventQueue();

        expect(order, ['awaiting-caller', 'subscriber']);
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

        await noStrategyRepo.onDispose();
      });
    });
  });
}
