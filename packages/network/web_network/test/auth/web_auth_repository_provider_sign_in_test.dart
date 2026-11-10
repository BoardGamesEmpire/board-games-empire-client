// Web sign-in through a sign-in provider (#583), driven through a REAL Dio.
//
// The same harness as `web_auth_repository_impl_body_test.dart`: the
// transport is swapped under a real Dio, so the status, the body and Dio's own
// handling of both are what production sees. The web flow posts to the
// strategy's `authorization_endpoint`, then hands the answer's `url` to the
// injected page navigator; the sign-in finishes on the page the provider
// sends the user back to, which is read once at startup.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/network.dart' show FailingAdapter;
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:logging/logging.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart' show LogRecordFormatter;

import 'package:web_network/src/auth/provider_sign_in_bindings.dart';
import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/network/web_dio_factory.dart';

const _kOrigin = 'https://bge.example.com';
const _kAuthBase = '/api/auth';
const _kStart = '$_kAuthBase/sign-in/social';
const _kProviderUrl =
    'https://provider.example/authorize?x=1&state=provider-state-secret';

const _kStrategy = OidcStrategy(
  providerId: 'authentik',
  displayName: 'Authentik',
  discoveryUrl: 'https://idp.example.com/.well-known/openid-configuration',
  authorizationEndpoint: _kStart,
  appSignInEndpoint: '$_kAuthBase/app-sign-in/start',
  appTokenEndpoint: '$_kAuthBase/app-sign-in/token',
);

ServerIdentity _identity() => const ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: _kOrigin,
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [_kStrategy],
);

/// Answers every request with [statusCode], [body] and any [headers], and
/// keeps each request it was asked. With a [gate], each answer waits for it.
class _StartRoute implements HttpClientAdapter {
  _StartRoute({
    this.statusCode = 200,
    this.body = '',
    this.headers = const {},
    this.gate,
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final Future<void>? gate;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await gate;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        for (final entry in headers.entries) entry.key: [entry.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// `WebDioFactory`'s shape: the page origin as the base URL, and every status
/// resolved as a response. [permissiveStatus] false is Dio's default, under
/// which a non-2xx throws with the response attached: an injected Dio can
/// produce it.
Dio _dio(HttpClientAdapter adapter, {bool permissiveStatus = true}) => Dio(
  BaseOptions(
    baseUrl: _kOrigin,
    validateStatus: permissiveStatus ? (_) => true : null,
    followRedirects: false,
  ),
)..httpClientAdapter = adapter;

String _answer(Object? url) => jsonEncode({'url': url, 'redirect': true});

Matcher _providerFailure(ProviderSignInFailureReason reason, {String? code}) =>
    isA<AuthProviderSignInException>()
        .having((e) => e.reason, 'reason', reason)
        .having((e) => e.code, 'code', code);

void main() {
  late List<Uri> left;
  late List<String> returnIds;

  setUp(() {
    left = [];
    returnIds = [];
  });

  WebProviderSignInBindings bindings({
    WebProviderSignInReturn? startupReturn,
    void Function(Uri url, String returnId)? leavePageFor,
  }) => WebProviderSignInBindings(
    leavePageFor:
        leavePageFor ??
        (url, returnId) {
          left.add(url);
          returnIds.add(returnId);
        },
    startupReturn: startupReturn,
  );

  WebAuthRepositoryImpl repoWith(
    Dio dio, {
    WebProviderSignInBindings? providerSignIn,
    Duration pageLeaveGrace = Duration.zero,
  }) {
    final repo = WebAuthRepositoryImpl(
      identity: _identity(),
      dio: dio,
      providerSignIn: providerSignIn,
      pageLeaveGrace: pageLeaveGrace,
    );
    addTearDown(repo.onDispose);
    return repo;
  }

  group('signInWithProvider', () {
    test('posts provider and a callbackURL and errorCallbackURL carrying a '
        'fresh return id to authorization_endpoint, then leaves for the url '
        'with the same id', () async {
      final route = _StartRoute(
        body: _answer('https://provider.example/authorize?x=1'),
      );
      final repo = repoWith(_dio(route), providerSignIn: bindings());

      await repo.signInWithProvider(_kStrategy);

      expect(left, [Uri.parse('https://provider.example/authorize?x=1')]);
      final returnId = returnIds.single;
      expect(returnId, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      final callback = '/?$providerSignInReturnKey=$returnId';
      final request = route.requests.single;
      expect(request.method, 'POST');
      // Relative, through this repository's Dio, whose base URL is the page
      // origin: the same way every other discovery path is posted.
      expect(request.path, _kStart);
      expect(request.uri, Uri.parse('$_kOrigin$_kStart'));
      expect(request.data, {
        'provider': 'authentik',
        'callbackURL': callback,
        'errorCallbackURL': callback,
      });
    });

    test('each attempt chooses its own return id', () async {
      final repo = repoWith(
        _dio(_StartRoute(body: _answer(_kProviderUrl))),
        providerSignIn: bindings(),
      );

      await repo.signInWithProvider(_kStrategy);
      await repo.signInWithProvider(_kStrategy);

      expect(returnIds, hasLength(2));
      expect(returnIds.first, isNot(returnIds.last));
    });

    test('a page that leaves never completes the call; one still here after '
        'the grace completes it as cancelled', () {
      fakeAsync((async) {
        final repo = repoWith(
          _dio(_StartRoute(body: _answer(_kProviderUrl))),
          providerSignIn: bindings(),
          pageLeaveGrace: WebAuthRepositoryImpl.defaultPageLeaveGrace,
        );
        ProviderSignInOutcome? outcome;
        unawaited(repo.signInWithProvider(_kStrategy).then((o) => outcome = o));

        async.elapse(
          WebAuthRepositoryImpl.defaultPageLeaveGrace -
              const Duration(milliseconds: 1),
        );
        expect(left, [Uri.parse(_kProviderUrl)]);
        expect(outcome, isNull, reason: 'the page may still be leaving');

        async.elapse(const Duration(milliseconds: 1));
        expect(outcome, isA<ProviderSignInCancelled>());
      });
    });

    test('a session that lands while the start is out keeps the page: the '
        'call is superseded and does not leave', () async {
      final gate = Completer<void>();
      final route = _StartRoute(
        body: _answer(_kProviderUrl),
        gate: gate.future,
      );
      final repo = repoWith(_dio(route), providerSignIn: bindings());

      final outcome = repo.signInWithProvider(_kStrategy);
      await pumpEventQueue();
      expect(route.requests, hasLength(1));
      // Another tab's sign-in, as the session monitor hands it over.
      repo.signedInInAnotherTab();
      gate.complete();

      await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
      expect(left, isEmpty);
    });

    test(
      "another tab's sign-out while the start is out still leaves: the "
      'user here asked for the provider, and no session replaced that',
      () async {
        final gate = Completer<void>();
        final route = _StartRoute(
          body: _answer(_kProviderUrl),
          gate: gate.future,
        );
        final repo = repoWith(_dio(route), providerSignIn: bindings());

        final outcome = repo.signInWithProvider(_kStrategy);
        await pumpEventQueue();
        repo.signedOutInAnotherTab();
        gate.complete();

        await expectLater(outcome, completion(isA<ProviderSignInCancelled>()));
        expect(left, [Uri.parse(_kProviderUrl)]);
      },
    );

    for (final permissive in [true, false]) {
      final shape = permissive ? 'a resolved' : 'a thrown';

      test('$shape 429 from /sign-in/social throws AuthRateLimitedException '
          'and does not leave the page', () async {
        final route = _StartRoute(
          statusCode: 429,
          body: '{"code":"RATE_LIMITED","message":"slow down"}',
          headers: {'x-retry-after': '7'},
        );
        final repo = repoWith(
          _dio(route, permissiveStatus: permissive),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.signInWithProvider(_kStrategy),
          throwsA(
            isA<AuthRateLimitedException>().having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 7),
            ),
          ),
        );
        expect(left, isEmpty);
      });

      // A provider that is down stays listed (#583), and this route answers
      // for it with a 404 and the code, after a wait of up to ten seconds.
      test('$shape 404 PROVIDER_NOT_FOUND throws '
          'AuthProviderSignInException(providerUnavailable) and does not '
          'leave the page', () async {
        final route = _StartRoute(
          statusCode: 404,
          body: '{"code":"PROVIDER_NOT_FOUND","message":"Provider not found"}',
        );
        final repo = repoWith(
          _dio(route, permissiveStatus: permissive),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.signInWithProvider(_kStrategy),
          throwsA(
            _providerFailure(
              ProviderSignInFailureReason.providerUnavailable,
              code: 'PROVIDER_NOT_FOUND',
            ),
          ),
        );
        expect(left, isEmpty);
      });

      // A code outside the provider table is the generic failure. Not the
      // credential grant's vocabulary: a 403 here is not a wrong password,
      // and a 409 is not a duplicate email.
      for (final status in [400, 401, 403, 404, 409, 500, 503]) {
        test('$shape $status with an unknown code throws '
            'AuthProviderSignInException(generic) and does not leave the '
            'page', () async {
          final route = _StartRoute(
            statusCode: status,
            body: '{"code":"SOMETHING","message":"no"}',
          );
          final repo = repoWith(
            _dio(route, permissiveStatus: permissive),
            providerSignIn: bindings(),
          );

          await expectLater(
            repo.signInWithProvider(_kStrategy),
            throwsA(
              _providerFailure(
                ProviderSignInFailureReason.generic,
                code: 'SOMETHING',
              ),
            ),
          );
          expect(left, isEmpty);
        });
      }

      for (final (label, body) in [
        ('no body', ''),
        ('a body that is not JSON', '<html><body>proxy</body></html>'),
        ('a code that is not a string', '{"code":404}'),
      ]) {
        test('$shape 404 with $label throws '
            'AuthProviderSignInException(generic) and does not leave the '
            'page', () async {
          final route = _StartRoute(statusCode: 404, body: body);
          final repo = repoWith(
            _dio(route, permissiveStatus: permissive),
            providerSignIn: bindings(),
          );

          await expectLater(
            repo.signInWithProvider(_kStrategy),
            throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
          );
          expect(left, isEmpty);
        });
      }
    }

    // The server holds the answer for up to ten seconds while a provider is
    // down (#583), which is the factory's own receive timeout: on that
    // timeout, the wait would read as an unreachable server.
    test('the start waits 30 seconds for its answer, and no longer to '
        'connect', () async {
      final route = _StartRoute(body: _answer(_kProviderUrl));
      final dio = const WebDioFactory().buildForServer(baseUrl: _kOrigin)
        ..httpClientAdapter = route;
      final repo = repoWith(dio, providerSignIn: bindings());

      await repo.signInWithProvider(_kStrategy);

      final sent = route.requests.single;
      expect(sent.receiveTimeout, const Duration(seconds: 30));
      expect(
        WebAuthRepositoryImpl.providerStartReceiveTimeout,
        const Duration(seconds: 30),
      );
      expect(sent.connectTimeout, dio.options.connectTimeout);
      expect(sent.receiveTimeout, greaterThan(dio.options.receiveTimeout!));
    });

    test('a 200 without url throws AuthProviderSignInException(generic) and '
        'does not leave the page', () async {
      final repo = repoWith(
        _dio(_StartRoute(body: '{"redirect":true}')),
        providerSignIn: bindings(),
      );

      await expectLater(
        repo.signInWithProvider(_kStrategy),
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(left, isEmpty);
    });

    for (final (label, body) in [
      ('a url that is not a string', _answer(42)),
      ('a url that does not parse', _answer('http://[::1')),
      ('a relative url', _answer('/authorize?x=1')),
      // A host does not make another scheme safe to navigate to.
      (
        'a javascript url with a host',
        _answer('javascript://provider.example/%0Aalert(1)'),
      ),
      ('an ftp url', _answer('ftp://provider.example/authorize')),
      ('a javascript url', _answer('javascript:alert(1)')),
      ('a url with no host', _answer('https:authorize')),
      ('a body that is a JSON array', '["https://provider.example"]'),
      ('a body that is not JSON', '<html><body>proxy</body></html>'),
      ('an empty body', ''),
    ]) {
      test('a 200 with $label throws AuthProviderSignInException(generic) and '
          'does not leave the page', () async {
        final repo = repoWith(
          _dio(_StartRoute(body: body)),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.signInWithProvider(_kStrategy),
          throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
        );
        expect(left, isEmpty);
      });
    }

    test('a transport failure is a network failure, and does not leave the '
        'page', () async {
      final repo = repoWith(
        _dio(FailingAdapter(DioExceptionType.connectionError)),
        providerSignIn: bindings(),
      );

      await expectLater(
        repo.signInWithProvider(_kStrategy),
        throwsA(isA<AuthNetworkException>()),
      );
      expect(left, isEmpty);
    });

    test('a page that cannot be left is a generic failure, not a raw '
        'error', () async {
      final repo = repoWith(
        _dio(_StartRoute(body: _answer(_kProviderUrl))),
        providerSignIn: bindings(
          leavePageFor: (url, _) =>
              throw StateError('storage refused for $url'),
        ),
      );

      await expectLater(
        repo.signInWithProvider(_kStrategy),
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
    });

    test('without bindings: unavailable, and signInWithProvider posts '
        'nothing', () async {
      final route = _StartRoute(body: _answer(_kProviderUrl));
      final repo = repoWith(_dio(route));

      expect(
        repo.providerSignInAvailability,
        isA<ProviderSignInUnsupportedDevice>(),
      );
      await expectLater(
        repo.signInWithProvider(_kStrategy),
        throwsA(_providerFailure(ProviderSignInFailureReason.generic)),
      );
      expect(route.requests, isEmpty);
    });
  });

  group('providerSignInAvailability', () {
    // No issuer check on web: the server handles the cookie flow itself.
    test('is available with the browser bindings, whatever the issuer', () {
      final repo = WebAuthRepositoryImpl(
        identity: _identity().copyWith(issuer: 'https://elsewhere.example'),
        dio: _dio(_StartRoute()),
        providerSignIn: bindings(),
      );
      addTearDown(repo.onDispose);

      expect(repo.providerSignInAvailability, isA<ProviderSignInAvailable>());
    });
  });

  group('takeProviderSignInReturn', () {
    test('hands back the startup failure once', () {
      final repo = repoWith(
        _dio(_StartRoute()),
        providerSignIn: bindings(
          startupReturn: const WebProviderSignInReturn(
            errorCode: 'SIGN_IN_PROVIDER_EMAIL_UNVERIFIED',
          ),
        ),
      );

      expect(
        repo.takeProviderSignInReturn(),
        _providerFailure(
          ProviderSignInFailureReason.emailUnverified,
          code: 'SIGN_IN_PROVIDER_EMAIL_UNVERIFIED',
        ),
      );
      expect(repo.takeProviderSignInReturn(), isNull);
    });

    test('an empty error code is the generic failure', () {
      final repo = repoWith(
        _dio(_StartRoute()),
        providerSignIn: bindings(
          startupReturn: const WebProviderSignInReturn(errorCode: ''),
        ),
      );

      expect(
        repo.takeProviderSignInReturn(),
        _providerFailure(ProviderSignInFailureReason.generic, code: ''),
      );
    });

    test('is null for a successful return', () {
      final repo = repoWith(
        _dio(_StartRoute()),
        providerSignIn: bindings(
          startupReturn: const WebProviderSignInReturn(),
        ),
      );

      expect(repo.takeProviderSignInReturn(), isNull);
    });

    test('is null when this page load is not a return', () {
      expect(
        repoWith(
          _dio(_StartRoute()),
          providerSignIn: bindings(),
        ).takeProviderSignInReturn(),
        isNull,
      );
      expect(repoWith(_dio(_StartRoute())).takeProviderSignInReturn(), isNull);
    });
  });

  // The provider's `url` carries its `state`, so it is never logged; only
  // outcomes and codes are.
  test('nothing logged contains the provider url or its state', () async {
    final records = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await subscription.cancel();
    });

    Future<void> attempt(
      String body, {
      void Function(Uri url, String returnId)? leavePageFor,
    }) async {
      final repo = repoWith(
        _dio(_StartRoute(body: body)),
        providerSignIn: bindings(leavePageFor: leavePageFor),
      );
      try {
        await repo.signInWithProvider(_kStrategy);
      } on AuthException {
        // The refusals are the point: each one logs.
      }
    }

    // A page that leaves, one that cannot, an address that is not one, and
    // an address that will not parse.
    await attempt(_answer(_kProviderUrl));
    await attempt(
      _answer(_kProviderUrl),
      leavePageFor: (url, _) => throw StateError('cannot leave for $url'),
    );
    await attempt(_answer('javascript:void("provider-state-secret")'));
    await attempt(_answer('http://[provider-state-secret'));
    expect(left, [Uri.parse(_kProviderUrl)]);

    const formatter = LogRecordFormatter(includeTimestamp: false);
    final lines = [
      for (final record in records) ...[
        formatter.formatLine(record),
        '${record.error}',
        '${record.stackTrace}',
      ],
    ];
    expect(
      records.where((r) => r.loggerName == 'bge.web.auth.repository'),
      isNotEmpty,
      reason: 'the refusals were logged, so the check below is not vacuous',
    );
    for (final line in lines) {
      expect(line, isNot(contains('provider-state-secret')));
      expect(line, isNot(contains('provider.example')));
    }
  });
}
