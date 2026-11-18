// The email/password requests both auth repositories send (#877).
//
// Driven through a REAL Dio over a recording `ScriptedServer`. The Dio
// defaults to `ResponseType.bytes`, under which Dio skips forcing
// `responseType` from the type argument, so only the per-request pin (#360)
// makes the request plain.

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:logging/logging.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart'
    show BgeLogger, LogRecordFormatter;

const _signIn = '$testAuthBasePath/sign-in/email';
const _signUp = '$testAuthBasePath/sign-up/email';

typedef _Wire = ({Dio dio, ScriptedServer server, List<RequestOptions> sent});

_Wire _wire({int status = 200, String body = '{"token":"t"}'}) {
  final server = ScriptedServer()
    ..on('POST', _signIn, (_) => ScriptedResponse(body, status: status))
    ..on('POST', _signUp, (_) => ScriptedResponse(body, status: status));
  final sent = <RequestOptions>[];
  final dio =
      Dio(BaseOptions(baseUrl: testServerUrl, responseType: ResponseType.bytes))
        ..httpClientAdapter = server
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              sent.add(options);
              handler.next(options);
            },
          ),
        );
  return (dio: dio, server: server, sent: sent);
}

void main() {
  group('postSignIn', () {
    test('posts the email and password to the sign-in endpoint, '
        'plain-bodied', () async {
      final (:dio, :server, :sent) = _wire();

      final response = await postSignIn(
        dio,
        testEmailAndPasswordStrategy(),
        email: 'a@example.com',
        password: 'secret',
      );

      expect(response.data, '{"token":"t"}');
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _signIn);
      expect(request.data, {'email': 'a@example.com', 'password': 'secret'});
      expect(sent.single.responseType, ResponseType.plain);
    });

    test('maps a thrown rejection as a credential grant', () async {
      final (:dio, server: _, sent: _) = _wire(
        status: 403,
        body: '{"code":"EMAIL_NOT_VERIFIED"}',
      );

      await expectLater(
        postSignIn(
          dio,
          testEmailAndPasswordStrategy(),
          email: 'a@example.com',
          password: 'secret',
        ),
        throwsA(isA<AuthEmailNotVerifiedException>()),
      );
    });
  });

  group('postSignUp', () {
    test('posts the username as `name`, and no absent names', () async {
      final (:dio, :server, :sent) = _wire();

      await postSignUp(
        dio,
        testEmailAndPasswordStrategy(),
        email: 'a@example.com',
        password: 'secret',
        username: 'ada',
      );

      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _signUp);
      expect(request.data, {
        'email': 'a@example.com',
        'password': 'secret',
        'name': 'ada',
      });
      expect(sent.single.responseType, ResponseType.plain);
    });

    test('posts firstName and lastName when given', () async {
      final (:dio, :server, sent: _) = _wire();

      await postSignUp(
        dio,
        testEmailAndPasswordStrategy(),
        email: 'a@example.com',
        password: 'secret',
        username: 'ada',
        firstName: 'Ada',
        lastName: 'Lovelace',
      );

      expect(server.requests.single.data, {
        'email': 'a@example.com',
        'password': 'secret',
        'name': 'ada',
        'firstName': 'Ada',
        'lastName': 'Lovelace',
      });
    });

    test('with sign-up disabled refuses before any request', () async {
      final (:dio, :server, sent: _) = _wire();

      await expectLater(
        postSignUp(
          dio,
          testEmailAndPasswordStrategy(signUpDisabled: true),
          email: 'a@example.com',
          password: 'secret',
          username: 'ada',
        ),
        throwsA(isA<AuthRegistrationDisabledException>()),
      );
      expect(server.requests, isEmpty);
    });

    test('with no sign-up endpoint refuses before any request', () async {
      final (:dio, :server, sent: _) = _wire();

      await expectLater(
        postSignUp(
          dio,
          const EmailAndPasswordStrategy(
            signUpDisabled: false,
            signInEndpoint: _signIn,
          ),
          email: 'a@example.com',
          password: 'secret',
          username: 'ada',
        ),
        throwsA(isA<AuthRegistrationDisabledException>()),
      );
      expect(server.requests, isEmpty);
    });

    test('maps a thrown rejection as a credential grant', () async {
      final (:dio, server: _, sent: _) = _wire(
        status: 422,
        body: '{"code":"USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"}',
      );

      await expectLater(
        postSignUp(
          dio,
          testEmailAndPasswordStrategy(),
          email: 'a@example.com',
          password: 'secret',
          username: 'ada',
        ),
        throwsA(isA<AuthEmailAlreadyExistsException>()),
      );
    });
  });

  group('requireEmailPasswordStrategy', () {
    late List<LogRecord> records;

    setUp(() {
      records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        Logger.root.level = previousLevel;
        await subscription.cancel();
      });
    });

    final missing = testServerIdentity().copyWith(strategies: []);

    Matcher unsupported() => throwsA(
      isA<AuthServerException>().having(
        (e) => e.message,
        'message',
        'This server does not support email/password authentication.',
      ),
    );

    test("returns the identity's strategy and logs nothing", () {
      final strategy = requireEmailPasswordStrategy(
        testServerIdentity(),
        log: BgeLogger('bge.auth.repository'),
        baseUrl: testServerUrl,
      );

      expect(strategy, testEmailAndPasswordStrategy());
      expect(records, isEmpty);
    });

    test('with no strategy and a logger, logs one redacted error, then '
        'throws', () {
      expect(
        () => requireEmailPasswordStrategy(
          missing,
          log: BgeLogger('bge.auth.repository'),
          baseUrl: 'https://user:pw@bge.example.com/api?token=x#frag',
        ),
        unsupported(),
      );

      final record = records.single;
      expect(record.loggerName, 'bge.auth.repository');
      expect(record.level, Level.SEVERE);
      expect(
        record.message,
        'Email/password strategy missing on cached identity',
      );
      expect(LogRecordFormatter.contextOf(record), {
        'base_url': 'https://bge.example.com/api',
        'has_strategies': false,
        'strategy_count': 0,
      });
    });

    test('with no strategy and no logger, throws and logs nothing', () {
      expect(() => requireEmailPasswordStrategy(missing), unsupported());
      expect(records, isEmpty);
    });

    test('a logger without a base URL, or the reverse, is refused', () {
      expect(
        () => requireEmailPasswordStrategy(
          testServerIdentity(),
          log: BgeLogger('bge.auth.repository'),
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => requireEmailPasswordStrategy(
          testServerIdentity(),
          baseUrl: testServerUrl,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
