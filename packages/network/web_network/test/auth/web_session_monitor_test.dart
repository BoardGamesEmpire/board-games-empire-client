import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart' show SessionConfirmation;
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/session_channel.dart';
import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/auth/web_session_monitor.dart';

import '../support/fake_session_channel.dart';

class MockDio extends Mock implements Dio {}

const _kAuthBase = '/api/auth';
const _kSession = '$_kAuthBase/get-session';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: _kSession,
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
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

/// The web session monitor (#432): what a tab does when another tab signs in
/// or out, when the page regains attention, and when work asks whose session
/// it is about to send as.
///
/// Driven against the real repository over a mocked Dio, because the
/// behaviour that matters is the repository's — whether a read is refused,
/// whose session it adopts — and a fake repository would assert the
/// monitor against the author's model of it.
/// Matches an authenticated state for [userId].
Matcher isSessionOf(String userId) => isA<AuthStateAuthenticated>().having(
  (s) => s.session.user.id,
  'user id',
  userId,
);

void main() {
  late MockDio dio;
  late WebAuthRepositoryImpl repo;
  late FakeSessionChannel channel;
  late StreamController<void> attention;
  late WebSessionMonitor monitor;

  setUpAll(() => registerFallbackValue(Options()));

  setUp(() {
    dio = MockDio();
    repo = WebAuthRepositoryImpl(identity: _identity(), dio: dio);
    channel = FakeSessionChannel();
    attention = StreamController<void>.broadcast();
    monitor = WebSessionMonitor(
      repository: repo,
      channel: channel,
      attention: attention.stream,
    );
  });

  tearDown(() async {
    await monitor.onDispose();
    await attention.close();
    await repo.onDispose();
  });

  void stubSession(String userId) {
    when(() => dio.get<String>(_kSession, options: any(named: 'options')))
        .thenAnswer((_) async => _sessionFor(userId));
  }

  Future<void> signedInAs(String userId) async {
    stubSession(userId);
    await repo.getSession();
    clearInteractions(dio);
  }

  group('confirm', () {
    test('is true while the cookie is still the scope user', () async {
      await signedInAs('user-a');
      stubSession('user-a');

      expect(await monitor.confirm('user-a'), SessionConfirmation.confirmed);
    });

    test('is false once the cookie is another user, and moves the tab to '
        'that user so the shell can switch', () async {
      await signedInAs('user-a');
      stubSession('user-b');

      expect(await monitor.confirm('user-a'), SessionConfirmation.notThisUser);
      expect(repo.currentAuthState, isSessionOf('user-b'));
    });

    test('calls made together share one read', () async {
      await signedInAs('user-a');
      stubSession('user-a');

      final answers = await Future.wait([
        monitor.confirm('user-a'),
        monitor.confirm('user-a'),
        monitor.confirm('user-a'),
      ]);

      expect(answers, everyElement(SessionConfirmation.confirmed));
      verify(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .called(1);
    });

    test('an answer is kept until the page regains attention', () async {
      await signedInAs('user-a');
      stubSession('user-a');
      await monitor.confirm('user-a');

      expect(await monitor.confirm('user-a'), SessionConfirmation.confirmed);
      verify(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .called(1);

      stubSession('user-b');
      attention.add(null);
      await pumpEventQueue();

      expect(await monitor.confirm('user-a'), SessionConfirmation.notThisUser);
    });

    test('an answer is kept until another tab signs in', () async {
      await signedInAs('user-a');
      stubSession('user-a');
      await monitor.confirm('user-a');

      stubSession('user-b');
      channel.deliver(SessionChange.signedIn);

      expect(await monitor.confirm('user-a'), SessionConfirmation.notThisUser);
      expect(await monitor.confirm('user-b'), SessionConfirmation.confirmed);
    });

    test('is false when the server cannot be reached, and asks again next '
        'time rather than keeping that', () async {
      await signedInAs('user-a');
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenThrow(
            DioException(
              type: DioExceptionType.connectionError,
              requestOptions: RequestOptions(path: ''),
            ),
          );

      expect(await monitor.confirm('user-a'), SessionConfirmation.unanswered);

      stubSession('user-a');
      expect(await monitor.confirm('user-a'), SessionConfirmation.confirmed);
    });

    test('is false in a tab another tab signed out', () async {
      await signedInAs('user-a');
      channel.deliver(SessionChange.signedOut);
      await pumpEventQueue();

      expect(await monitor.confirm('user-a'), SessionConfirmation.notThisUser);
      verifyZeroInteractions(dio);
    });

    // The rehydrate trigger hears focus through Flutter's lifecycle, the
    // monitor through its own DOM listener, and the two run in one dispatch
    // in an order neither controls. A hydrate the trigger starts can call in
    // before the monitor has heard the event that should void its answer.
    test(
      'an event in the same task as the call voids the kept answer',
      () async {
        await signedInAs('user-a');
        stubSession('user-a');
        await monitor.confirm('user-a');

        final answer = monitor.confirm('user-a');
        stubSession('user-b');
        attention.add(null);

        expect(await answer, SessionConfirmation.notThisUser);
      },
    );
  });

  group('what this tab does', () {
    test('a sign-out here is posted to the other tabs', () async {
      await signedInAs('user-a');
      when(() => dio.post<String>(any(), options: any(named: 'options')))
          .thenAnswer(
            (_) async => Response<String>(
              statusCode: 200,
              requestOptions: RequestOptions(path: ''),
            ),
          );

      await repo.signOut();
      await pumpEventQueue();

      expect(channel.posted, [SessionChange.signedOut]);
    });

    test('a broadcast it heard is not posted back', () async {
      await signedInAs('user-a');
      stubSession('user-b');

      channel
        ..deliver(SessionChange.signedOut)
        ..deliver(SessionChange.signedIn);
      await pumpEventQueue();

      expect(channel.posted, isEmpty);
    });
  });

  group('the page regaining attention', () {
    test('re-reads the cookie, which catches a sign-in no broadcast reached '
        'this tab with', () async {
      await signedInAs('user-a');

      stubSession('user-b');
      attention.add(null);
      await pumpEventQueue();

      expect(repo.currentAuthState, isSessionOf('user-b'));
    });

    test('leaves the startup check to decide on its own', () async {
      stubSession('user-a');

      attention.add(null);
      await pumpEventQueue();

      verifyZeroInteractions(dio);
      expect(repo.currentAuthState, const AuthStateUnknown());
    });

    test('during the startup check, costs no read once the check has '
        'decided', () async {
      attention.add(null);
      await pumpEventQueue();

      stubSession('user-a');
      await repo.getSession();
      await pumpEventQueue();

      verify(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .called(1);
    });

    // Each event is a separate return to the page; the bindings fold the
    // focus and visibilitychange of one return into one. The cookie can
    // change between two returns with no broadcast, from a build of the app
    // that sends none, and the first return's read may have left before it.
    test('again before the first read is back reads again, and the later '
        'answer stands', () async {
      await signedInAs('user-a');
      final slow = Completer<Response<String>>();
      final answers = [slow.future, Future.value(_sessionFor('user-b'))];
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) => answers.removeAt(0));

      attention.add(null);
      await pumpEventQueue();
      attention.add(null);
      await pumpEventQueue();
      slow.complete(_sessionFor('user-a'));
      await pumpEventQueue();

      expect(repo.currentAuthState, isSessionOf('user-b'));
      expect(await monitor.confirm('user-a'), SessionConfirmation.notThisUser);
    });

    test('after a broadcast, reads again though a read is still out', () async {
      await signedInAs('user-a');
      final slow = Completer<Response<String>>();
      final answers = [slow.future, Future.value(_sessionFor('user-b'))];
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) => answers.removeAt(0));

      attention.add(null);
      await pumpEventQueue();
      channel.deliver(SessionChange.signedIn);
      attention.add(null);
      await pumpEventQueue();
      slow.complete(_sessionFor('user-a'));
      await pumpEventQueue();

      expect(repo.currentAuthState, isSessionOf('user-b'));
    });
  });

  group('a broadcast from another tab', () {
    test('a sign-out ends the session here, without a request', () async {
      await signedInAs('user-a');

      channel.deliver(SessionChange.signedOut);
      await pumpEventQueue();

      expect(repo.currentAuthState, const AuthStateUnauthenticated());
      verifyZeroInteractions(dio);
    });

    test('a sign-in after it re-reads the cookie and takes the new user, '
        'though the sign-out left the latch up', () async {
      await signedInAs('user-a');
      channel.deliver(SessionChange.signedOut);
      await pumpEventQueue();

      stubSession('user-b');
      channel.deliver(SessionChange.signedIn);
      await pumpEventQueue();

      expect(repo.currentAuthState, isSessionOf('user-b'));
    });

    // The bloc ignores the repository while its startup check runs, so a
    // read landing then would move the repository and leave the bloc behind.
    // But the check's own read may have left before the other tab's cookie
    // existed, so it is read again once the check has decided.
    test('a sign-in during the startup check is read again once the check '
        'has decided', () async {
      channel.deliver(SessionChange.signedIn);
      await pumpEventQueue();
      verifyZeroInteractions(dio);

      final answers = [_noSession(), _sessionFor('user-b')];
      when(() => dio.get<String>(_kSession, options: any(named: 'options')))
          .thenAnswer((_) async => answers.removeAt(0));
      await repo.getSession();
      await pumpEventQueue();

      expect(repo.currentAuthState, isSessionOf('user-b'));
    });

    test('a sign-in under a tab still presenting the old user moves it to '
        'the new one', () async {
      await signedInAs('user-a');

      stubSession('user-b');
      channel.deliver(SessionChange.signedIn);
      await pumpEventQueue();

      expect(repo.currentAuthState, isSessionOf('user-b'));
    });
  });
}
