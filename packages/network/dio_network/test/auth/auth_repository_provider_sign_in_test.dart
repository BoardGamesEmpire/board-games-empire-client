// Native provider sign-in through AuthRepositoryImpl (#583): PKCE and `state`,
// the in-app browser tab behind its seam, the checks on the return, and the
// code exchange at the token endpoint the attempt recorded.
//
// Driven through a REAL Dio, as the body suite is, so the token exchange runs
// Dio's own body pipeline and the classification sees what production sees.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart' show ProviderSignInBrowser;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:observability/observability.dart' show LogRecordFormatter;

import 'package:dio_network/src/auth/auth_repository_impl.dart';
import 'package:dio_network/src/auth/provider_sign_in/pkce.dart';
import 'package:dio_network/src/auth/token_storage_service.dart';
import 'package:dio_network/src/network/decode_json_body.dart';

class MockTokenStorage extends Mock implements TokenStorageService {}

const _kServer = 'https://api.example.com';
const _kAuthBase = '/api/auth';
const _kStartPath = '$_kAuthBase/app-sign-in/start';
const _kTokenPath = '$_kAuthBase/app-sign-in/token';

/// Distinctive enough that finding it in a log line can only mean it leaked.
const _kCode = 'one-time-code-7f3a9b51';

/// The token a password sign-in or sign-up is granted, told apart from the
/// provider grant's `session-tok-granted`.
const _kPasswordToken = 'password-tok-granted';

/// A discovery path no address can be made from.
const _kMalformedEndpoint = 'https://[bad/app-sign-in';

const _kStrategy = OidcStrategy(
  providerId: 'authentik',
  displayName: 'Authentik',
  discoveryUrl: 'https://idp.example.com/.well-known/openid-configuration',
  authorizationEndpoint: '$_kAuthBase/sign-in/social',
  appSignInEndpoint: _kStartPath,
  appTokenEndpoint: _kTokenPath,
);

ServerIdentity _identity({String issuer = _kServer}) => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: issuer,
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
    _kStrategy,
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

Map<String, dynamic> _grantJson() => {
  'token': 'session-tok-granted',
  'user': _wireUser(),
};

Map<String, dynamic> _sessionJson() => {
  'session': {
    'id': 'sess-1',
    'token': 'session-tok-renewed',
    'expiresAt': '2099-01-01T00:00:00.000Z',
    'userId': 'user-1',
  },
  'user': _wireUser(),
};

ResponseBody _json(
  Object body,
  int status, {
  Map<String, String> headers = const {},
}) => ResponseBody.fromString(
  body is String ? body : jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    for (final entry in headers.entries) entry.key: [entry.value],
  },
);

/// The server side of the flow: answers the token route with [tokenAnswer]
/// and the session check with a confirmed session, and records every request.
class _ServerAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  Future<ResponseBody> Function() tokenAnswer = () async =>
      _json(_grantJson(), 200);

  List<RequestOptions> get tokenPosts =>
      requests.where((r) => r.uri.path.endsWith(_kTokenPath)).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (path.endsWith(_kTokenPath)) return tokenAnswer();
    if (path.endsWith('$_kAuthBase/get-session')) {
      return _json(_sessionJson(), 200);
    }
    if (path.endsWith('$_kAuthBase/sign-in/email') ||
        path.endsWith('$_kAuthBase/sign-up/email')) {
      return _json({'token': _kPasswordToken, 'user': _wireUser()}, 200);
    }
    if (path.endsWith('$_kAuthBase/sign-out')) {
      return _json({'success': true}, 200);
    }
    throw StateError('no canned answer for ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

/// The in-app browser tab: hands out one [Completer] per call and records the
/// URL and callback scheme each call opened with.
class FakeProviderSignInBrowser implements ProviderSignInBrowser {
  FakeProviderSignInBrowser({this.isSupported = true});

  @override
  final bool isSupported;

  final List<Uri> opened = [];
  final List<String> callbackSchemes = [];
  final List<Completer<Uri?>> _tabs = [];

  @override
  Future<Uri?> authenticate({
    required Uri url,
    required String callbackScheme,
  }) {
    opened.add(url);
    callbackSchemes.add(callbackScheme);
    final tab = Completer<Uri?>();
    _tabs.add(tab);
    return tab.future;
  }

  void returnTo(int call, Uri? address) => _tabs[call].complete(address);

  void fail(int call, Object error) => _tabs[call].completeError(error);
}

/// What the server sends the tab back to for the attempt [opened] started.
///
/// [state] defaults to the attempt's own; pass [keepState] false to leave it
/// out entirely.
Uri _returnFor(
  Uri opened, {
  String scheme = 'bge',
  String host = 'oauth',
  String? code = _kCode,
  String? state,
  bool keepState = true,
  String? iss = _kServer,
  String? error,
  String? errorDescription,
}) => Uri(
  scheme: scheme,
  host: host,
  queryParameters: {
    'code': ?code,
    'error': ?error,
    'error_description': ?errorDescription,
    if (keepState) 'state': state ?? opened.queryParameters['state']!,
    'iss': ?iss,
  },
);

TypeMatcher<AuthProviderSignInException> _providerFailure(
  ProviderSignInFailureReason reason, {
  String? code,
}) => isA<AuthProviderSignInException>()
    .having((e) => e.reason, 'reason', reason)
    .having((e) => e.code, 'code', code);

void main() {
  late MockTokenStorage storage;

  setUp(() {
    storage = MockTokenStorage();
    when(() => storage.clear()).thenAnswer((_) async {});
    when(
      () => storage.store(
        token: any(named: 'token'),
        expiresAt: any(named: 'expiresAt'),
        persistedAt: any(named: 'persistedAt'),
        user: any(named: 'user'),
      ),
    ).thenAnswer((_) async {});
    when(() => storage.retrieve()).thenAnswer(
      (_) async => StoredSession(
        token: 'session-tok-granted',
        expiresAt: null,
        persistedAt: DateTime.utc(2026, 1, 1),
        user: AuthUser.fromJson(_wireUser()),
      ),
    );
  });

  ({AuthRepositoryImpl repo, _ServerAdapter server}) build({
    FakeProviderSignInBrowser? browser,
    String serverUrl = _kServer,
    String issuer = _kServer,
    _ServerAdapter? server,
    bool permissiveStatus = true,
    Future<Object?> Function(String) decodeJson = decodeJsonBody,
  }) {
    final adapter = server ?? _ServerAdapter();
    final dio = Dio(
      BaseOptions(
        baseUrl: serverUrl,
        validateStatus: permissiveStatus ? (_) => true : null,
      ),
    )..httpClientAdapter = adapter;
    final repo = AuthRepositoryImpl(
      identity: _identity(issuer: issuer),
      serverUrl: serverUrl,
      tokenStorage: storage,
      dio: dio,
      providerBrowser: browser ?? FakeProviderSignInBrowser(),
      decodeJson: decodeJson,
    );
    addTearDown(repo.onDispose);
    return (repo: repo, server: adapter);
  }

  /// Lets the repository reach its next await before the test acts.
  Future<void> settle() => pumpEventQueue();

  void verifyNothingStored() => verifyNever(
    () => storage.store(
      token: any(named: 'token'),
      expiresAt: any(named: 'expiresAt'),
      persistedAt: any(named: 'persistedAt'),
      user: any(named: 'user'),
    ),
  );

  group('signInWithProvider() start', () {
    test('opens app_sign_in_endpoint with provider, bge://oauth, an S256 '
        'challenge of the verifier it later sends, and state', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();

      final opened = browser.opened.single;
      expect(
        opened.replace(query: ''),
        Uri.parse('$_kServer$_kStartPath?'),
        reason: 'the start route, on the server the attempt is for',
      );
      expect(browser.callbackSchemes.single, 'bge');

      final query = opened.queryParameters;
      expect(query.keys, {
        'provider',
        'redirect_uri',
        'code_challenge',
        'code_challenge_method',
        'state',
      });
      expect(query['provider'], 'authentik');
      expect(query['redirect_uri'], 'bge://oauth');
      expect(query['code_challenge_method'], 'S256');
      expect(query['code_challenge'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(query['state'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));

      browser.returnTo(0, _returnFor(opened));
      await outcome;

      final post = server.tokenPosts.single;
      expect(post.method, 'POST');
      final body = post.data as Map<String, dynamic>;
      expect(body.keys, {'code', 'code_verifier'});
      expect(body['code'], _kCode);
      final verifier = body['code_verifier'] as String;
      expect(verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(codeChallengeS256(verifier), query['code_challenge']);
    });

    test('two attempts use a fresh state and verifier each', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, server: _) = build(browser: browser);

      unawaited(
        repo.signInWithProvider(_kStrategy).then<void>((_) {}, onError: (_) {}),
      );
      unawaited(
        repo.signInWithProvider(_kStrategy).then<void>((_) {}, onError: (_) {}),
      );
      await settle();

      final [first, second] = browser.opened;
      expect(
        first.queryParameters['state'],
        isNot(second.queryParameters['state']),
      );
      expect(
        first.queryParameters['code_challenge'],
        isNot(second.queryParameters['code_challenge']),
      );
      browser
        ..returnTo(0, null)
        ..returnTo(1, null);
    });

    test('a server reached under a path prefix keeps it on both the start '
        'route and the token route', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(
        browser: browser,
        serverUrl: 'https://example.com/bge',
        issuer: 'https://example.com/bge/',
      );

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();

      final opened = browser.opened.single;
      expect(
        opened.replace(query: ''),
        Uri.parse('https://example.com/bge$_kStartPath?'),
      );

      browser.returnTo(0, _returnFor(opened, iss: 'https://example.com/bge/'));
      await outcome;

      expect(
        server.tokenPosts.single.uri,
        Uri.parse('https://example.com/bge$_kTokenPath'),
      );
    });
  });

  group('signInWithProvider() return', () {
    test('a successful return exchanges the code at the recorded token '
        'endpoint and signs in', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single));

      final result = await outcome;

      expect(
        result,
        isA<ProviderSignInCompleted>().having(
          (c) => c.session.token,
          'session token',
          'session-tok-renewed',
        ),
      );
      expect(server.tokenPosts.single.uri, Uri.parse('$_kServer$_kTokenPath'));
      verify(
        () => storage.store(
          token: 'session-tok-granted',
          expiresAt: null,
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      ).called(1);
      expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
    });

    test(
      'the return is accepted whatever the case of its scheme and host',
      () async {
        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);

        final outcome = repo.signInWithProvider(_kStrategy);
        await settle();
        browser.returnTo(
          0,
          _returnFor(browser.opened.single, scheme: 'BGE', host: 'OAuth'),
        );

        expect(await outcome, isA<ProviderSignInCompleted>());
        expect(server.tokenPosts, hasLength(1));
      },
    );

    test(
      'a closed browser returns ProviderSignInCancelled and posts nothing',
      () async {
        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);

        final outcome = repo.signInWithProvider(_kStrategy);
        await settle();
        browser.returnTo(0, null);

        expect(await outcome, isA<ProviderSignInCancelled>());
        expect(server.requests, isEmpty);
        verifyNothingStored();
      },
    );

    test('a return with another state is refused and posts nothing', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(
        0,
        _returnFor(browser.opened.single, state: randomUrlSafeToken()),
      );

      await expectLater(
        outcome,
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(server.requests, isEmpty);
    });

    test('a return with no state is refused and posts nothing', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single, keepState: false));

      await expectLater(
        outcome,
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(server.requests, isEmpty);
    });

    test('a return whose query does not decode is refused as generic, not a '
        'raw FormatException, and posts nothing', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      // `%FF` is not UTF-8, so `Uri.queryParameters` throws on it.
      browser.returnTo(0, Uri.parse('bge://oauth?code=$_kCode&state=%FF'));

      await expectLater(
        outcome,
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(server.requests, isEmpty);
      verifyNothingStored();
    });

    for (final (label, iss) in [
      ('no iss', null),
      ("another server's iss", 'https://evil.example.com'),
    ]) {
      test('a return with $label is refused and posts nothing', () async {
        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);

        final outcome = repo.signInWithProvider(_kStrategy);
        await settle();
        browser.returnTo(0, _returnFor(browser.opened.single, iss: iss));

        await expectLater(
          outcome,
          throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
        );
        expect(server.requests, isEmpty);
      });
    }

    test('an iss that differs only by a trailing slash is accepted', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single, iss: '$_kServer/'));

      expect(await outcome, isA<ProviderSignInCompleted>());
      expect(server.tokenPosts, hasLength(1));
    });

    for (final (label, scheme, host) in [
      ('another host than oauth', 'bge', 'server'),
      ('another scheme than bge', 'evil', 'oauth'),
    ]) {
      test('a return to $label is refused', () async {
        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);

        final outcome = repo.signInWithProvider(_kStrategy);
        await settle();
        browser.returnTo(
          0,
          _returnFor(browser.opened.single, scheme: scheme, host: host),
        );

        await expectLater(
          outcome,
          throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
        );
        expect(server.requests, isEmpty);
      });
    }

    test('an error return maps through forCode: REGISTRATION_DISABLED → '
        'registrationDisabled', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(
        0,
        _returnFor(
          browser.opened.single,
          code: null,
          error: 'REGISTRATION_DISABLED',
          errorDescription: 'Registration is disabled',
        ),
      );

      await expectLater(
        outcome,
        throwsA(
          _providerFailure(
            ProviderSignInFailureReason.registrationDisabled,
            code: 'REGISTRATION_DISABLED',
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('an error return with no error_description still maps '
        '(state_mismatch → startAgain)', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(
        0,
        _returnFor(browser.opened.single, code: null, error: 'state_mismatch'),
      );

      await expectLater(
        outcome,
        throwsA(
          _providerFailure(
            ProviderSignInFailureReason.startAgain,
            code: 'state_mismatch',
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('an error return with another state is refused as generic, not '
        'mapped', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, server: _) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(
        0,
        _returnFor(
          browser.opened.single,
          code: null,
          error: 'REGISTRATION_DISABLED',
          state: randomUrlSafeToken(),
        ),
      );

      await expectLater(
        outcome,
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
    });

    test(
      'a return with neither code nor error is refused and posts nothing',
      () async {
        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);

        final outcome = repo.signInWithProvider(_kStrategy);
        await settle();
        browser.returnTo(0, _returnFor(browser.opened.single, code: null));

        await expectLater(
          outcome,
          throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
        );
        expect(server.requests, isEmpty);
      },
    );

    test('a browser failure propagates as the generic refusal it is', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.fail(
        0,
        const AuthProviderSignInException(ProviderSignInFailureReason.generic),
      );

      await expectLater(
        outcome,
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(server.requests, isEmpty);
    });

    test('a browser failure that is not an AuthException leaves as the '
        'generic refusal', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, server: _) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      final cause = StateError('tab could not open');
      browser.fail(0, cause);

      await expectLater(
        outcome,
        throwsA(
          _providerFailure(ProviderSignInFailureReason.generic)
              .having((e) => e.cause, 'cause', same(cause)),
        ),
      );
    });
  });

  group('signInWithProvider() token exchange', () {
    Future<Object?> exchangeAnswered(ResponseBody answer) async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);
      server.tokenAnswer = () async => answer;

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single));
      try {
        return await outcome;
      } on Object catch (error) {
        return error;
      }
    }

    test(
      'a 400 APP_SIGN_IN_CODE_INVALID from the token route → startAgain',
      () async {
        expect(
          await exchangeAnswered(
            _json({
              'code': 'APP_SIGN_IN_CODE_INVALID',
              'message': 'Invalid code',
            }, 400),
          ),
          _providerFailure(
            ProviderSignInFailureReason.startAgain,
            code: 'APP_SIGN_IN_CODE_INVALID',
          ),
        );
        verifyNothingStored();
      },
    );

    test(
      'a 403 BANNED_USER from the token route is the generic refusal',
      () async {
        expect(
          await exchangeAnswered(
            _json({'code': 'BANNED_USER', 'message': 'Banned'}, 403),
          ),
          _providerFailure(
            ProviderSignInFailureReason.generic,
            code: 'BANNED_USER',
          ),
        );
      },
    );

    test('a 429 from the token route throws AuthRateLimitedException with its '
        'wait', () async {
      expect(
        await exchangeAnswered(
          _json(
            {'code': 'RATE_LIMITED', 'message': 'Too many requests'},
            429,
            headers: {'x-retry-after': '7'},
          ),
        ),
        isA<AuthRateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 7),
        ),
      );
      verifyNothingStored();
    });

    test('a 500 from the token route is a server fault', () async {
      expect(
        await exchangeAnswered(_json('<html>oops</html>', 500)),
        isA<AuthServerException>().having(
          (e) => e.statusCode,
          'statusCode',
          500,
        ),
      );
    });

    test('a thrown 400 (an injected Dio that throws on a rejection) maps '
        'the same way', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser, permissiveStatus: false);
      server.tokenAnswer = () async =>
          _json({'code': 'APP_SIGN_IN_CODE_INVALID'}, 400);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single));

      await expectLater(
        outcome,
        throwsA(
          _providerFailure(
            ProviderSignInFailureReason.startAgain,
            code: 'APP_SIGN_IN_CODE_INVALID',
          ),
        ),
      );
    });

    test('a transport failure is a network failure', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);
      server.tokenAnswer = () async => throw DioException(
        type: DioExceptionType.connectionError,
        requestOptions: RequestOptions(path: _kTokenPath),
      );

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single));

      await expectLater(outcome, throwsA(isA<AuthNetworkException>()));
      verifyNothingStored();
    });
  });

  group('overlapping attempts and server switches', () {
    test("a second attempt replaces the first: the first's late return "
        'throws AuthSupersededException and posts nothing', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final first = repo.signInWithProvider(_kStrategy);
      await settle();
      final second = repo.signInWithProvider(_kStrategy);
      await settle();

      browser.returnTo(0, _returnFor(browser.opened[0]));
      await expectLater(first, throwsA(isA<AuthSupersededException>()));
      expect(server.requests, isEmpty);
      verifyNothingStored();

      // The first's ending does not clear the attempt that replaced it.
      browser.returnTo(1, _returnFor(browser.opened[1]));
      expect(await second, isA<ProviderSignInCompleted>());
      expect(server.tokenPosts, hasLength(1));
    });

    test("the first attempt's state does not complete the second", () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final first = repo.signInWithProvider(_kStrategy);
      await settle();
      final second = repo.signInWithProvider(_kStrategy);
      await settle();

      browser.returnTo(1, _returnFor(browser.opened[0]));
      await expectLater(
        second,
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(server.requests, isEmpty);

      browser.returnTo(0, null);
      await expectLater(first, throwsA(isA<AuthSupersededException>()));
    });

    test('a browser failure after the attempt was replaced is superseded, '
        'not a refusal', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, server: _) = build(browser: browser);

      final first = repo.signInWithProvider(_kStrategy);
      await settle();
      unawaited(
        repo.signInWithProvider(_kStrategy).then<void>((_) {}, onError: (_) {}),
      );
      await settle();

      browser.fail(
        0,
        const AuthProviderSignInException(ProviderSignInFailureReason.generic),
      );
      await expectLater(first, throwsA(isA<AuthSupersededException>()));
      browser.returnTo(1, null);
    });

    test('switching servers mid-flow: a disposed repository refuses its '
        'return and posts nothing', () async {
      // One browser seam, as production builds it once for the app.
      final browser = FakeProviderSignInBrowser();
      final (repo: serverA, server: dioA) = build(browser: browser);
      final (repo: serverB, server: dioB) = build(
        browser: browser,
        serverUrl: 'https://other.example.com',
        issuer: 'https://other.example.com',
      );

      final attemptA = serverA.signInWithProvider(_kStrategy);
      await settle();
      await serverA.onDispose();
      final attemptB = serverB.signInWithProvider(_kStrategy);
      await settle();

      browser.returnTo(0, _returnFor(browser.opened[0]));
      await expectLater(attemptA, throwsA(isA<AuthSupersededException>()));
      expect(dioA.requests, isEmpty);
      expect(dioB.requests, isEmpty);
      verifyNothingStored();

      // B's own attempt is untouched by A's teardown.
      browser.returnTo(
        1,
        _returnFor(browser.opened[1], iss: 'https://other.example.com'),
      );
      expect(await attemptB, isA<ProviderSignInCompleted>());
      expect(
        dioB.tokenPosts.single.uri,
        Uri.parse('https://other.example.com$_kTokenPath'),
      );
      expect(dioA.requests, isEmpty);
    });

    for (final (label, interrupt)
        in <(String, Future<void> Function(AuthRepositoryImpl))>[
          ('the repository is disposed', (repo) => repo.onDispose()),
          ('the user signs out', (repo) => repo.signOut()),
          (
            'a second attempt starts',
            (repo) async => unawaited(
              repo
                  .signInWithProvider(_kStrategy)
                  .then<void>((_) {}, onError: (_) {}),
            ),
          ),
        ]) {
      test('when $label while the token exchange is in flight, the grant is '
          'not adopted', () async {
        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);
        final grant = Completer<ResponseBody>();
        server.tokenAnswer = () => grant.future;

        final outcome = repo.signInWithProvider(_kStrategy);
        await settle();
        browser.returnTo(0, _returnFor(browser.opened.single));
        await settle();
        expect(server.tokenPosts, hasLength(1), reason: 'the POST is out');

        await interrupt(repo);
        grant.complete(_json(_grantJson(), 200));

        await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
        verifyNothingStored();
        expect(
          server.requests.where((r) => r.uri.path.endsWith('get-session')),
          isEmpty,
          reason: 'no reconcile for a grant that was not adopted',
        );
      });
    }

    test('a token refusal that lands after the repository was disposed is '
        'superseded, not a refusal to show', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);
      final answer = Completer<ResponseBody>();
      server.tokenAnswer = () => answer.future;

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single));
      await settle();

      await repo.onDispose();
      answer.complete(_json({'code': 'APP_SIGN_IN_CODE_INVALID'}, 400));

      await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
    });

    test('a token exchange that fails after the repository was disposed is '
        'superseded, not a network failure', () async {
      // A server switch closes the per-server Dio too, which fails the POST.
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);
      final answer = Completer<ResponseBody>();
      server.tokenAnswer = () => answer.future;

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single));
      await settle();

      await repo.onDispose();
      answer.completeError(
        DioException(
          type: DioExceptionType.cancel,
          requestOptions: RequestOptions(path: _kTokenPath),
        ),
      );

      await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
    });

    test('a repository disposed while the grant body is decoding adopts '
        'nothing', () async {
      final browser = FakeProviderSignInBrowser();
      final decoding = Completer<void>();
      final release = Completer<void>();
      final (:repo, server: _) = build(
        browser: browser,
        decodeJson: (raw) async {
          decoding.complete();
          await release.future;
          return decodeJsonBody(raw);
        },
      );

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(0, _returnFor(browser.opened.single));
      await decoding.future;

      await repo.onDispose();
      release.complete();

      await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
      verifyNothingStored();
    });
  });

  group('a newer credential intent retires a pending attempt', () {
    test('a sign-out: the tab returning afterwards is superseded, posts '
        'nothing and stores nothing', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(browser: browser);

      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      await repo.signOut();

      browser.returnTo(0, _returnFor(browser.opened.single));
      await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
      expect(server.tokenPosts, isEmpty);
      verifyNothingStored();
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    for (final (label, passwordGrant)
        in <(String, Future<AuthResponse> Function(AuthRepositoryImpl))>[
          (
            'a password sign-in',
            (repo) => repo.signIn(email: 'a@b.c', password: 'pw'),
          ),
          (
            'a sign-up',
            (repo) =>
                repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
          ),
        ]) {
      test('$label: the tab returning afterwards is superseded and does not '
          'sign the provider account in over it', () async {
        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);

        final outcome = repo.signInWithProvider(_kStrategy);
        await settle();
        await passwordGrant(repo);

        browser.returnTo(0, _returnFor(browser.opened.single));
        await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
        expect(server.tokenPosts, isEmpty);
        verify(
          () => storage.store(
            token: _kPasswordToken,
            expiresAt: null,
            persistedAt: any(named: 'persistedAt'),
            user: any(named: 'user'),
          ),
        ).called(1);
        verifyNever(
          () => storage.store(
            token: 'session-tok-granted',
            expiresAt: any(named: 'expiresAt'),
            persistedAt: any(named: 'persistedAt'),
            user: any(named: 'user'),
          ),
        );
      });
    }
  });

  group('a discovery path that is not an address on this server', () {
    for (final (label, strategy) in [
      (
        'app_sign_in_endpoint',
        const OidcStrategy(
          providerId: 'authentik',
          displayName: 'Authentik',
          discoveryUrl:
              'https://idp.example.com/.well-known/openid-configuration',
          authorizationEndpoint: '$_kAuthBase/sign-in/social',
          appSignInEndpoint: _kMalformedEndpoint,
          appTokenEndpoint: _kTokenPath,
        ),
      ),
      (
        'app_token_endpoint',
        const OidcStrategy(
          providerId: 'authentik',
          displayName: 'Authentik',
          discoveryUrl:
              'https://idp.example.com/.well-known/openid-configuration',
          authorizationEndpoint: '$_kAuthBase/sign-in/social',
          appSignInEndpoint: _kStartPath,
          appTokenEndpoint: _kMalformedEndpoint,
        ),
      ),
      (
        'an app_token_endpoint on another host',
        const OidcStrategy(
          providerId: 'authentik',
          displayName: 'Authentik',
          discoveryUrl:
              'https://idp.example.com/.well-known/openid-configuration',
          authorizationEndpoint: '$_kAuthBase/sign-in/social',
          appSignInEndpoint: _kStartPath,
          appTokenEndpoint: 'https://elsewhere.example.com/app-sign-in/token',
        ),
      ),
    ]) {
      test('in $label is refused as generic before the tab opens or any '
          'request goes out', () async {
        final records = <LogRecord>[];
        final previousLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        final subscription = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          Logger.root.level = previousLevel;
          await subscription.cancel();
        });

        final browser = FakeProviderSignInBrowser();
        final (:repo, :server) = build(browser: browser);

        await expectLater(
          repo.signInWithProvider(strategy),
          throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
        );
        expect(browser.opened, isEmpty);
        expect(server.requests, isEmpty);
        expect(
          records.map(LogRecordFormatter.contextOf),
          contains(equals({'check': 'endpoint'})),
        );
      });
    }
  });

  group('providerSignInAvailability', () {
    test('a supported browser on a server whose issuer is its address is '
        'available', () {
      final (:repo, server: _) = build();

      expect(repo.providerSignInAvailability, isA<ProviderSignInAvailable>());
    });

    test('an issuer that differs only by a trailing slash is available', () {
      final (:repo, server: _) = build(issuer: '$_kServer/');

      expect(repo.providerSignInAvailability, isA<ProviderSignInAvailable>());
    });

    test('an issuer on another host reports '
        'ProviderSignInAddressMismatch(issuer) and opens no browser', () async {
      final browser = FakeProviderSignInBrowser();
      final (:repo, :server) = build(
        browser: browser,
        serverUrl: 'https://192.168.1.5',
      );

      expect(
        repo.providerSignInAvailability,
        isA<ProviderSignInAddressMismatch>().having(
          (m) => m.configuredAddress,
          'configuredAddress',
          _kServer,
        ),
      );
      await expectLater(
        repo.signInWithProvider(_kStrategy),
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(browser.opened, isEmpty);
      expect(server.requests, isEmpty);
    });

    test(
      'an unsupported browser reports ProviderSignInUnsupportedDevice',
      () async {
        final browser = FakeProviderSignInBrowser(isSupported: false);
        final (:repo, :server) = build(browser: browser);

        expect(
          repo.providerSignInAvailability,
          isA<ProviderSignInUnsupportedDevice>(),
        );
        await expectLater(
          repo.signInWithProvider(_kStrategy),
          throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
        );
        expect(browser.opened, isEmpty);
        expect(server.requests, isEmpty);
      },
    );

    test('the default browser is the unsupported one', () {
      final repo = AuthRepositoryImpl(
        identity: _identity(),
        serverUrl: _kServer,
        tokenStorage: storage,
        dio: Dio(),
      );
      addTearDown(repo.onDispose);

      expect(
        repo.providerSignInAvailability,
        isA<ProviderSignInUnsupportedDevice>(),
      );
    });
  });

  test('takeProviderSignInReturn is always null on native', () {
    final (:repo, server: _) = build();

    expect(repo.takeProviderSignInReturn(), isNull);
  });

  test('nothing logged contains the state, the code or the verifier', () async {
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await subscription.cancel();
    });

    final browser = FakeProviderSignInBrowser();
    final (:repo, :server) = build(browser: browser);
    var call = 0;

    Future<void> attempt(Uri Function(Uri opened) answer) async {
      final outcome = repo.signInWithProvider(_kStrategy);
      await settle();
      browser.returnTo(call, answer(browser.opened[call]));
      call += 1;
      try {
        await outcome;
      } on AuthException {
        // The refusals are the point: each one logs.
      }
    }

    // A completed sign-in, a token refusal, an error return, and a return
    // refused on each of its checks.
    await attempt(_returnFor);
    server.tokenAnswer = () async =>
        _json({'code': 'APP_SIGN_IN_CODE_INVALID'}, 400);
    await attempt(_returnFor);
    await attempt(
      (opened) => _returnFor(opened, code: null, error: 'access_denied'),
    );
    await attempt((opened) => _returnFor(opened, host: 'server'));
    await attempt((opened) => _returnFor(opened, state: 'forged'));
    await attempt((opened) => _returnFor(opened, iss: null));
    await attempt((opened) => _returnFor(opened, code: null));

    final secrets = <String>{
      _kCode,
      for (final opened in browser.opened) ...[
        opened.toString(),
        opened.queryParameters['state']!,
        opened.queryParameters['code_challenge']!,
      ],
      for (final post in server.tokenPosts)
        (post.data as Map<String, dynamic>)['code_verifier'] as String,
    };
    expect(
      server.tokenPosts,
      hasLength(2),
      reason: 'two verifiers to look for',
    );

    const formatter = LogRecordFormatter(includeTimestamp: false);
    final lines = [
      for (final record in records) ...[
        formatter.formatLine(record),
        '${record.error}',
        '${record.stackTrace}',
      ],
    ];
    expect(
      records.where((r) => r.loggerName == 'bge.auth.repository'),
      isNotEmpty,
      reason: 'the refusals were logged, so the check below is not vacuous',
    );
    for (final secret in secrets) {
      for (final line in lines) {
        expect(line, isNot(contains(secret)));
      }
    }
  });
}
