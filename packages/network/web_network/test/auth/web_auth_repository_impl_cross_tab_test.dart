import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/session_channel.dart';
import 'package:web_network/src/auth/web_auth_repository_impl.dart';

class MockDio extends Mock implements Dio {}

const _kAuthBase = '/api/auth';
const _kSession = '$_kAuthBase/get-session';
const _kSignOut = '$_kAuthBase/sign-out';
const _kSignIn = '$_kAuthBase/sign-in/email';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: _kSession,
  signOutEndpoint: _kSignOut,
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
  strategies: [
    EmailAndPasswordStrategy(signUpDisabled: true, signInEndpoint: _kSignIn),
  ],
);

Response<String> _grantFor(String userId, {bool carriesSession = true}) =>
    Response(
      data: jsonEncode({
        'token': carriesSession ? 'grant-$userId' : null,
        'user': {
          'id': userId,
          'name': 'name-$userId',
          'email': '$userId@example.com',
          'emailVerified': true,
          'createdAt': '2024-01-01T00:00:00.000Z',
          'updatedAt': '2024-01-01T00:00:00.000Z',
        },
      }),
      statusCode: 200,
      requestOptions: RequestOptions(path: ''),
    );

Response<String> _sessionFor(String userId) => Response(
  data: jsonEncode({
    'session': {
      'id': 'sess-$userId',
      'token': 'tok-$userId',
      'expiresAt': '2099-01-01T00:00:00.000Z',
      'userId': userId,
    },
    'user': {
      'id': userId,
      'name': 'name-$userId',
      'email': '$userId@example.com',
      'emailVerified': true,
      'createdAt': '2024-01-01T00:00:00.000Z',
      'updatedAt': '2024-01-01T00:00:00.000Z',
    },
  }),
  statusCode: 200,
  requestOptions: RequestOptions(path: ''),
);

/// BetterAuth's answer for no session: 200 with a null body.
Response<String> _noSession() => Response(
  data: 'null',
  statusCode: 200,
  requestOptions: RequestOptions(path: ''),
);

Response<String> _ok() =>
    Response(statusCode: 200, requestOptions: RequestOptions(path: ''));

/// The two entry points another tab's broadcast drives (#432).
///
/// Every tab holds its own copy of this repository over one shared cookie.
/// A sign-out or sign-in in one tab reaches the others only as a broadcast,
/// and these are what a receiving tab does with it.
void main() {
  late MockDio dio;
  late WebAuthRepositoryImpl repo;

  setUpAll(() => registerFallbackValue(Options()));

  setUp(() {
    dio = MockDio();
    repo = WebAuthRepositoryImpl(identity: _identity(), dio: dio);
  });

  tearDown(() async => repo.onDispose());

  void stubSession(String userId) {
    when(() => dio.get<String>(_kSession, options: any(named: 'options')))
        .thenAnswer((_) async => _sessionFor(userId));
  }

  void stubSignIn(Response<String> grant) {
    when(
      () => dio.post<String>(
        _kSignIn,
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenAnswer((_) async => grant);
  }

  group('signedOutInAnotherTab', () {
    test('ends the session here without sending a revocation', () async {
      stubSession('user-a');
      await repo.getSession();

      repo.signedOutInAnotherTab();

      expect(repo.currentAuthState, const AuthStateUnauthenticated());
      verifyNever(
        () => dio.post<String>(any(), options: any(named: 'options')),
      );
    });

    test('refuses later session reads, as a failed revocation would, so a '
        'cookie the other tab could not revoke is not adopted here', () async {
      stubSession('user-a');
      await repo.getSession();

      repo.signedOutInAnotherTab();
      clearInteractions(dio);

      expect(await repo.getSession(), isNull);
      verifyNever(() => dio.get<String>(any(), options: any(named: 'options')));
      expect(repo.currentAuthState, const AuthStateUnauthenticated());
    });
  });

  group('signedInInAnotherTab', () {
    test('releases the latch a sign-out broadcast raised, so the next read '
        'adopts the new user', () async {
      stubSession('user-a');
      await repo.getSession();
      repo.signedOutInAnotherTab();

      repo.signedInInAnotherTab();
      stubSession('user-b');

      final session = await repo.getSession();
      expect(session?.user.id, 'user-b');
      expect(
        repo.currentAuthState,
        isA<AuthStateAuthenticated>().having(
          (s) => s.session.user.id,
          'user id',
          'user-b',
        ),
      );
    });

    test('a revocation of this tab that fails after the other tab signed in '
        'does not latch over the cookie that sign-in set', () async {
      stubSession('user-a');
      await repo.getSession();
      when(() => dio.post<String>(_kSignOut, options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response<String>(
              statusCode: 500,
              requestOptions: RequestOptions(path: ''),
            ),
          );

      final signingOut = repo.signOut();
      repo.signedInInAnotherTab();
      await signingOut;

      stubSession('user-b');
      expect((await repo.getSession())?.user.id, 'user-b');
    });

    test('a revocation of this tab that fails after the other tab signed in '
        'reads that sign-in\'s cookie, which was refused while it was '
        'out', () async {
      stubSession('user-a');
      await repo.getSession();
      final revocation = Completer<Response<String>>();
      when(() => dio.post<String>(_kSignOut, options: any(named: 'options')))
          .thenAnswer((_) => revocation.future);

      final signingOut = repo.signOut();
      repo.signedInInAnotherTab();
      stubSession('user-b');
      await repo.rereadSession();
      expect(repo.currentAuthState, const AuthStateUnauthenticated());

      revocation.complete(
        Response<String>(
          statusCode: 500,
          requestOptions: RequestOptions(path: ''),
        ),
      );
      await signingOut;

      expect(
        repo.currentAuthState,
        isA<AuthStateAuthenticated>().having(
          (s) => s.session.user.id,
          'user id',
          'user-b',
        ),
      );
    });

    test('a sign-in here whose reconcile lands after the other tab\'s newer '
        'cookie was read does not put this tab back on its own', () async {
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) async => _noSession());
      await repo.getSession();

      // This tab's reconcile left under its own cookie and is slow. The
      // other tab's sign-in replaces the cookie, and the read after its
      // broadcast comes back first.
      final reconcile = Completer<Response<String>>();
      final answers = [
        reconcile.future,
        Future.value(_sessionFor('user-b')),
        Future.value(_sessionFor('user-b')),
      ];
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) => answers.removeAt(0));
      stubSignIn(_grantFor('user-a'));

      final signingIn = repo.signIn(email: 'a@example.com', password: 'pw');
      await pumpEventQueue();
      repo.signedInInAnotherTab();
      await repo.rereadSession();

      reconcile.complete(_sessionFor('user-a'));
      final session = await signingIn;

      expect(session.user.id, 'user-b');
      expect(
        repo.currentAuthState,
        isA<AuthStateAuthenticated>().having(
          (s) => s.session.user.id,
          'user id',
          'user-b',
        ),
      );
    });

    test('a sign-in here whose reconcile cannot be answered after the other '
        'tab signed in does not keep its own grant', () async {
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) async => _noSession());
      await repo.getSession();

      final reconcile = Completer<Response<String>>();
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) => reconcile.future);
      stubSignIn(_grantFor('user-a'));

      final signingIn = repo.signIn(email: 'a@example.com', password: 'pw');
      await pumpEventQueue();
      repo.signedInInAnotherTab();
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenThrow(
            DioException(
              type: DioExceptionType.connectionError,
              requestOptions: RequestOptions(path: ''),
            ),
          );
      reconcile.complete(_sessionFor('user-a'));

      await expectLater(signingIn, throwsA(isA<AuthException>()));
      expect(repo.currentAuthState, isNot(isA<AuthStateAuthenticated>()));
    });
  });

  group('rereadSession', () {
    test('a read a sign-in overtook does not undo it', () async {
      // The tab is on the sign-in form.
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) async => _noSession());
      await repo.getSession();

      // The page regains focus and re-reads, but slowly: the read left before
      // the sign-in's cookie existed. The sign-in's own read is quick.
      final slow = Completer<Response<String>>();
      final answers = [slow.future, Future.value(_sessionFor('user-a'))];
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) => answers.removeAt(0));
      stubSignIn(_grantFor('user-a'));

      final rereading = repo.rereadSession();
      await repo.signIn(email: 'a@example.com', password: 'pw');
      slow.complete(_noSession());
      await rereading;

      expect(
        repo.currentAuthState,
        isA<AuthStateAuthenticated>().having(
          (s) => s.session.user.id,
          'user id',
          'user-a',
        ),
      );
    });

    test(
      'asks nothing while a sign-out latch is up, as getSession does',
      () async {
        stubSession('user-a');
        await repo.getSession();
        repo.signedOutInAnotherTab();
        clearInteractions(dio);

        await repo.rereadSession();

        verifyNever(
          () => dio.get<String>(any(), options: any(named: 'options')),
        );
        expect(repo.currentAuthState, const AuthStateUnauthenticated());
      },
    );
  });

  group('localChanges', () {
    test('a sign-out here is announced before its revocation resolves, so '
        'other tabs stop presenting the session at once', () async {
      final announced = <SessionChange>[];
      repo.localChanges.listen(announced.add);
      when(() => dio.post<String>(_kSignOut, options: any(named: 'options')))
          .thenAnswer(
            (_) => Future.delayed(const Duration(milliseconds: 50), () {
              return Response<String>(
                statusCode: 200,
                requestOptions: RequestOptions(path: ''),
              );
            }),
          );

      final signingOut = repo.signOut();
      await pumpEventQueue();
      expect(announced, [SessionChange.signedOut]);
      await signingOut;
      expect(announced, [SessionChange.signedOut]);
    });

    test('a sign-in whose grant carries a session is announced', () async {
      final announced = <SessionChange>[];
      repo.localChanges.listen(announced.add);
      stubSignIn(_grantFor('user-b'));
      stubSession('user-b');

      await repo.signIn(email: 'b@example.com', password: 'pw');
      await pumpEventQueue();

      expect(announced, [SessionChange.signedIn]);
    });

    test('a 2xx grant that carries no session is not announced: it set no '
        'cookie, and a receiving tab would release its latch over the old '
        'one', () async {
      final announced = <SessionChange>[];
      repo.localChanges.listen(announced.add);
      stubSignIn(_grantFor('user-b', carriesSession: false));
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response<String>(
              data: 'null',
              statusCode: 200,
              requestOptions: RequestOptions(path: ''),
            ),
          );

      await expectLater(
        repo.signIn(email: 'b@example.com', password: 'pw'),
        throwsA(isA<AuthException>()),
      );
      await pumpEventQueue();

      expect(announced, isEmpty);
    });

    // #346 across tabs: the revocation's `Set-Cookie: Max-Age=0` deletes by
    // name, so it took the other tab's newer cookie with it.
    test('a late revocation that deleted another tab\'s newer cookie is '
        'announced again, so that tab hears its cookie is gone', () async {
      stubSession('user-a');
      await repo.getSession();
      final announced = <SessionChange>[];
      repo.localChanges.listen(announced.add);
      final revocation = Completer<Response<String>>();
      when(() => dio.post<String>(_kSignOut, options: any(named: 'options')))
          .thenAnswer((_) => revocation.future);

      final signingOut = repo.signOut();
      repo.signedInInAnotherTab();
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) async => _noSession());
      revocation.complete(_ok());
      await signingOut;
      await pumpEventQueue();

      expect(announced, [SessionChange.signedOut, SessionChange.signedOut]);
    });

    test('a revocation that lands before any newer sign-in is announced '
        'once', () async {
      stubSession('user-a');
      await repo.getSession();
      final announced = <SessionChange>[];
      repo.localChanges.listen(announced.add);
      when(() => dio.post<String>(_kSignOut, options: any(named: 'options')))
          .thenAnswer((_) async => _ok());

      await repo.signOut();
      await pumpEventQueue();

      expect(announced, [SessionChange.signedOut]);
    });

    test('what another tab did is not announced back', () async {
      final announced = <SessionChange>[];
      repo.localChanges.listen(announced.add);

      repo
        ..signedOutInAnotherTab()
        ..signedInInAnotherTab();
      await pumpEventQueue();

      expect(announced, isEmpty);
    });
  });
}
