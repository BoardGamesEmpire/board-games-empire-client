// Web sign-in methods (#582), driven through a REAL Dio.
//
// The same harness as `web_auth_repository_provider_sign_in_test.dart`: the
// transport is swapped under a real Dio, so the status, the body and Dio's own
// handling of both are what production sees. A link posts `link-social`,
// then hands the answer's `url` to the injected page navigator with a marker
// that records the link; the link finishes on the page the provider sends the
// user back to, which is read once at startup.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart' show FailingAdapter;
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:logging/logging.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart' show LogRecordFormatter;

import 'package:web_network/src/auth/provider_sign_in_bindings.dart';
import 'package:web_network/src/auth/session_channel.dart';
import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/network/web_dio_factory.dart';

const String _kOrigin = testServerUrl;
const _kLink = '$testAuthBasePath/link-social';
const _kReturnPath = '/settings/sign-in-methods';
const _kProviderUrl =
    'https://provider.example/authorize?x=1&state=provider-state-secret';

const _kStrategy = OidcStrategy(
  providerId: 'authentik',
  displayName: 'Authentik',
  discoveryUrl: 'https://idp.example.com/.well-known/openid-configuration',
  authorizationEndpoint: '$testAuthBasePath/sign-in/social',
  appSignInEndpoint: '$testAuthBasePath/app-sign-in/start',
  appTokenEndpoint: '$testAuthBasePath/app-sign-in/token',
);

// A live `GET /api/auth/list-accounts` answer (task 0 probe, 2026-11-19).
const _kLiveList =
    '[{"accountId":"TmeL0uxivrLYLQdAZ3WdQ4sIGv8PkW5M",'
    '"providerId":"credential",'
    '"userId":"TmeL0uxivrLYLQdAZ3WdQ4sIGv8PkW5M",'
    '"createdAt":"2026-11-19T18:38:40.649Z",'
    '"updatedAt":"2026-11-19T18:38:40.649Z",'
    '"id":"6UJgqBrNUba7ms7JrIvBYXKG5hvDXGWS","scopes":[]}]';

// better-auth answers a stale session's link with the bare body, no envelope.
const _kNeedsRecentSignIn =
    '{"code":"PROVIDER_LINK_NEEDS_RECENT_SIGN_IN",'
    '"message":"Sign in again to link"}';

final String _kLastAccount = jsonEncode({
  'message': "You can't unlink your last account",
  'code': 'FAILED_TO_UNLINK_LAST_ACCOUNT',
});

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

/// [_sessionJson] signed in as [userId].
String _sessionAs(String userId) {
  final json = _sessionJson();
  (json['session'] as Map<String, dynamic>)['userId'] = userId;
  (json['user'] as Map<String, dynamic>)['id'] = userId;
  return jsonEncode(json);
}

/// Answers each request with the next of [bodies], all 200, and the last one
/// from then on.
class _Bodies implements HttpClientAdapter {
  _Bodies(this.bodies);

  final List<String> bodies;
  var _next = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = bodies[_next < bodies.length ? _next++ : bodies.length - 1];
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ServerIdentity _identity() =>
    testServerIdentity().copyWith(strategies: [_kStrategy]);

/// Answers every request with [statusCode], [body] and any [headers], and
/// keeps each request it was asked. With a [gate], each answer waits for it.
class _Route implements HttpClientAdapter {
  _Route({
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

/// Answers the link start with [link], once [linkGate] completes, and each
/// session read with the next of [sessions], all 200.
class _ByPath implements HttpClientAdapter {
  _ByPath({required this.link, required this.sessions, this.linkGate});

  final String link;
  final List<String> sessions;
  final Future<void>? linkGate;
  var _nextSession = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String body;
    if (options.path.endsWith('/link-social')) {
      await linkGate;
      body = link;
    } else {
      body = sessions[_nextSession++];
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
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

Matcher _linkFailure(ProviderLinkFailureReason reason, {String? code}) =>
    isA<AuthProviderLinkException>()
        .having((e) => e.reason, 'reason', reason)
        .having((e) => e.code, 'code', code);

void main() {
  late List<Uri> left;
  late List<String> markers;

  setUp(() {
    left = [];
    markers = [];
  });

  WebProviderSignInBindings bindings({
    WebProviderSignInReturn? startupReturn,
    void Function(Uri url, String marker)? leavePageFor,
  }) => WebProviderSignInBindings(
    leavePageFor:
        leavePageFor ??
        (url, marker) {
          left.add(url);
          markers.add(marker);
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

  group('linkProvider', () {
    test('posts provider and a callbackURL and errorCallbackURL on the return '
        'path carrying a fresh return id to link-social, then leaves for the '
        'url with a link marker naming the provider and the same id', () async {
      final route = _Route(body: _answer(_kProviderUrl));
      final repo = repoWith(_dio(route), providerSignIn: bindings());

      await repo.linkProvider(_kStrategy, returnPath: _kReturnPath);

      expect(left, [Uri.parse(_kProviderUrl)]);
      final marker = markers.single;
      final match = RegExp(
        r'^link:authentik:([A-Za-z0-9_-]{22})$',
      ).firstMatch(marker);
      expect(match, isNotNull, reason: marker);
      final returnId = match!.group(1);

      final request = route.requests.single;
      expect(request.method, 'POST');
      expect(request.path, _kLink);
      expect(request.uri, Uri.parse('$_kOrigin$_kLink'));
      final data = request.data as Map<String, dynamic>;
      final callback = data['callbackURL'] as String;
      expect(
        callback,
        startsWith('/settings/sign-in-methods?$providerSignInReturnKey='),
      );
      expect(callback, '$_kReturnPath?$providerSignInReturnKey=$returnId');
      expect(data, {
        'provider': 'authentik',
        'callbackURL': callback,
        'errorCallbackURL': callback,
      });
    });

    test('each attempt chooses its own return id', () async {
      final repo = repoWith(
        _dio(_Route(body: _answer(_kProviderUrl))),
        providerSignIn: bindings(),
      );

      await repo.linkProvider(_kStrategy, returnPath: _kReturnPath);
      await repo.linkProvider(_kStrategy, returnPath: _kReturnPath);

      expect(markers, hasLength(2));
      expect(markers.first, isNot(markers.last));
    });

    test('a page that leaves never completes the call; one still here after '
        'the grace completes it normally', () {
      fakeAsync((async) {
        final repo = repoWith(
          _dio(_Route(body: _answer(_kProviderUrl))),
          providerSignIn: bindings(),
          pageLeaveGrace: WebAuthRepositoryImpl.defaultPageLeaveGrace,
        );
        var completed = false;
        unawaited(
          repo
              .linkProvider(_kStrategy, returnPath: _kReturnPath)
              .then((_) => completed = true),
        );

        async.elapse(
          WebAuthRepositoryImpl.defaultPageLeaveGrace -
              const Duration(milliseconds: 1),
        );
        expect(left, [Uri.parse(_kProviderUrl)]);
        expect(completed, isFalse, reason: 'the page may still be leaving');

        async.elapse(const Duration(milliseconds: 1));
        expect(completed, isTrue);
      });
    });

    // The link the server starts belongs to the session that asked for it
    // (#582). Unlike a sign-in's start, a sign-out counts too: it ends that
    // session.
    for (final (label, change)
        in <(String, FutureOr<void> Function(WebAuthRepositoryImpl))>[
          ("another tab's sign-in", (repo) => repo.signedInInAnotherTab()),
          ("another tab's sign-out", (repo) => repo.signedOutInAnotherTab()),
          ('a sign-out here', (repo) => repo.signOut()),
        ]) {
      test('$label while the link start is out keeps the page: the call is '
          'superseded and does not leave', () async {
        final gate = Completer<void>();
        final route = _Route(body: _answer(_kProviderUrl), gate: gate.future);
        final repo = repoWith(_dio(route), providerSignIn: bindings());

        final outcome = repo.linkProvider(_kStrategy, returnPath: _kReturnPath);
        await pumpEventQueue();
        expect(route.requests, hasLength(1));
        final changed = change(repo);
        gate.complete();

        await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
        await changed;
        expect(left, isEmpty);
      });
    }

    // A session read moves neither counter, so the user the tab shows is
    // checked too: a session the server ended, or another tab's sign-in read
    // here before that tab announced it.
    for (final (label, reread, supersedes) in <(String, String, bool)>[
      ('a session read as a different user', _sessionAs('user-2'), true),
      ('a session read that finds none', 'null', true),
      ('a session read as the same user', _sessionAs('user-1'), false),
    ]) {
      test(
        '$label while the link start is out '
        '${supersedes ? 'supersedes it and does not leave' : 'leaves'}',
        () async {
          final gate = Completer<void>();
          final route = _ByPath(
            link: _answer(_kProviderUrl),
            sessions: [_sessionAs('user-1'), reread],
            linkGate: gate.future,
          );
          final repo = repoWith(_dio(route), providerSignIn: bindings());
          expect(await repo.getSession(), isNotNull);

          final outcome = repo.linkProvider(
            _kStrategy,
            returnPath: _kReturnPath,
          );
          await pumpEventQueue();
          await repo.rereadSession();
          gate.complete();

          if (supersedes) {
            await expectLater(outcome, throwsA(isA<AuthSupersededException>()));
            expect(left, isEmpty);
          } else {
            await outcome;
            expect(left, hasLength(1));
          }
        },
      );
    }

    // A link moves no session, so nothing is announced to the other tabs.
    test('a link announces nothing to the other tabs', () async {
      final repo = repoWith(
        _dio(_Route(body: _answer(_kProviderUrl))),
        providerSignIn: bindings(),
      );
      final announced = <SessionChange>[];
      repo.localChanges.listen(announced.add);

      await repo.linkProvider(_kStrategy, returnPath: _kReturnPath);
      await pumpEventQueue();

      expect(left, hasLength(1));
      expect(announced, isEmpty);
    });

    for (final permissive in [true, false]) {
      final shape = permissive ? 'a resolved' : 'a thrown';

      test('$shape 403 PROVIDER_LINK_NEEDS_RECENT_SIGN_IN throws '
          'needsRecentSignIn and does not leave the page', () async {
        final route = _Route(statusCode: 403, body: _kNeedsRecentSignIn);
        final repo = repoWith(
          _dio(route, permissiveStatus: permissive),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
          throwsA(
            _linkFailure(
              ProviderLinkFailureReason.needsRecentSignIn,
              code: 'PROVIDER_LINK_NEEDS_RECENT_SIGN_IN',
            ),
          ),
        );
        expect(left, isEmpty);
      });

      test('$shape 429 throws AuthRateLimitedException and does not leave '
          'the page', () async {
        final route = _Route(
          statusCode: 429,
          body: '{"code":"RATE_LIMITED","message":"slow down"}',
          headers: {'x-retry-after': '7'},
        );
        final repo = repoWith(
          _dio(route, permissiveStatus: permissive),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
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

      test('$shape 404 PROVIDER_NOT_FOUND throws providerUnavailable and does '
          'not leave the page', () async {
        final route = _Route(
          statusCode: 404,
          body: '{"code":"PROVIDER_NOT_FOUND","message":"Provider not found"}',
        );
        final repo = repoWith(
          _dio(route, permissiveStatus: permissive),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
          throwsA(
            _linkFailure(
              ProviderLinkFailureReason.providerUnavailable,
              code: 'PROVIDER_NOT_FOUND',
            ),
          ),
        );
        expect(left, isEmpty);
      });

      test('$shape 500 with no code throws AuthServerException(500) and does '
          'not leave the page', () async {
        final route = _Route(statusCode: 500, body: '<html></html>');
        final repo = repoWith(
          _dio(route, permissiveStatus: permissive),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
          throwsA(
            isA<AuthServerException>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
          ),
        );
        expect(left, isEmpty);
      });
    }

    // The server holds a start for up to ten seconds while a provider is
    // down, as it does a sign-in's (#583).
    test('the start waits 30 seconds for its answer, and no longer to '
        'connect', () async {
      final route = _Route(body: _answer(_kProviderUrl));
      final dio = const WebDioFactory().buildForServer(baseUrl: _kOrigin)
        ..httpClientAdapter = route;
      final repo = repoWith(dio, providerSignIn: bindings());

      await repo.linkProvider(_kStrategy, returnPath: _kReturnPath);

      final sent = route.requests.single;
      expect(
        sent.receiveTimeout,
        WebAuthRepositoryImpl.providerStartReceiveTimeout,
      );
      expect(sent.connectTimeout, dio.options.connectTimeout);
      expect(sent.responseType, ResponseType.plain);
    });

    for (final (label, body) in [
      ('no url', '{"redirect":true}'),
      ('a relative url', _answer('/authorize?x=1')),
      ('a javascript url', _answer('javascript:alert(1)')),
      ('a body that is not JSON', '<html><body>proxy</body></html>'),
      ('an empty body', ''),
    ]) {
      test('a 200 with $label throws AuthProviderLinkException(generic) and '
          'does not leave the page', () async {
        final repo = repoWith(
          _dio(_Route(body: body)),
          providerSignIn: bindings(),
        );

        await expectLater(
          repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
          throwsA(_linkFailure(ProviderLinkFailureReason.generic)),
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
        repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
        throwsA(isA<AuthNetworkException>()),
      );
      expect(left, isEmpty);
    });

    test('a page that cannot be left is a generic failure, not a raw '
        'error', () async {
      final repo = repoWith(
        _dio(_Route(body: _answer(_kProviderUrl))),
        providerSignIn: bindings(
          leavePageFor: (url, _) =>
              throw StateError('storage refused for $url'),
        ),
      );

      await expectLater(
        repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
        throwsA(_linkFailure(ProviderLinkFailureReason.generic)),
      );
    });

    test('without bindings: not supported, and linkProvider posts '
        'nothing', () async {
      final route = _Route(body: _answer(_kProviderUrl));
      final repo = repoWith(_dio(route));

      expect(repo.providerLinkSupported, isFalse);
      await expectLater(
        repo.linkProvider(_kStrategy, returnPath: _kReturnPath),
        throwsA(_linkFailure(ProviderLinkFailureReason.generic)),
      );
      expect(route.requests, isEmpty);
    });
  });

  group('providerLinkSupported', () {
    test('is true with the browser bindings', () {
      expect(
        repoWith(
          _dio(_Route()),
          providerSignIn: bindings(),
        ).providerLinkSupported,
        isTrue,
      );
    });

    test('is false with no bindings', () {
      expect(repoWith(_dio(_Route())).providerLinkSupported, isFalse);
    });
  });

  group('a link return (#582)', () {
    const linked = WebProviderSignInReturn(linkProviderId: 'authentik');

    test('a link success return is not announced as a sign-in, and '
        'takeProviderSignInReturn() is null', () async {
      // The control: in this same harness, a sign-in's success return is
      // announced on the first read that finds the session.
      for (final (startupReturn, expected) in [
        (const WebProviderSignInReturn(), [SessionChange.signedIn]),
        (linked, <SessionChange>[]),
      ]) {
        final repo = repoWith(
          _dio(_Route(body: jsonEncode(_sessionJson()))),
          providerSignIn: bindings(startupReturn: startupReturn),
        );
        final announced = <SessionChange>[];
        repo.localChanges.listen(announced.add);

        expect(await repo.getSession(), isNotNull);
        await pumpEventQueue();

        expect(
          announced,
          expected,
          reason: 'linkProviderId: ${startupReturn.linkProviderId}',
        );
      }

      expect(
        repoWith(
          _dio(_Route()),
          providerSignIn: bindings(startupReturn: linked),
        ).takeProviderSignInReturn(),
        isNull,
      );
    });

    test('takeProviderLinkReturn() returns ProviderLinkSucceeded(authentik) '
        'once, then null', () {
      final repo = repoWith(
        _dio(_Route()),
        providerSignIn: bindings(startupReturn: linked),
      );

      expect(
        repo.takeProviderLinkReturn(),
        isA<ProviderLinkSucceeded>().having(
          (r) => r.providerId,
          'providerId',
          'authentik',
        ),
      );
      expect(repo.takeProviderLinkReturn(), isNull);
    });

    test('a failed link return maps '
        'account_already_linked_to_different_user', () {
      final repo = repoWith(
        _dio(_Route()),
        providerSignIn: bindings(
          startupReturn: const WebProviderSignInReturn(
            linkProviderId: 'authentik',
            errorCode: 'account_already_linked_to_different_user',
          ),
        ),
      );

      expect(
        repo.takeProviderLinkReturn(),
        isA<ProviderLinkFailed>()
            .having((r) => r.providerId, 'providerId', 'authentik')
            .having(
              (r) => r.failure,
              'failure',
              _linkFailure(
                ProviderLinkFailureReason.alreadyLinkedElsewhere,
                code: 'account_already_linked_to_different_user',
              ),
            ),
      );
      expect(repo.takeProviderLinkReturn(), isNull);
    });

    test('an empty error code is the generic failure', () {
      final repo = repoWith(
        _dio(_Route()),
        providerSignIn: bindings(
          startupReturn: const WebProviderSignInReturn(
            linkProviderId: 'authentik',
            errorCode: '',
          ),
        ),
      );

      expect(
        repo.takeProviderLinkReturn(),
        isA<ProviderLinkFailed>().having(
          (r) => r.failure,
          'failure',
          _linkFailure(ProviderLinkFailureReason.generic, code: ''),
        ),
      );
    });

    test("a failed link return's error never surfaces as a sign-in's, and "
        'taking the sign-in return first leaves the link return', () {
      final repo = repoWith(
        _dio(_Route()),
        providerSignIn: bindings(
          startupReturn: const WebProviderSignInReturn(
            linkProviderId: 'authentik',
            errorCode: 'access_denied',
          ),
        ),
      );

      expect(repo.takeProviderSignInReturn(), isNull);
      expect(repo.takeProviderLinkReturn(), isA<ProviderLinkFailed>());
    });

    test("a sign-in return is never a link's, and taking the link return "
        'first leaves the sign-in return', () {
      final repo = repoWith(
        _dio(_Route()),
        providerSignIn: bindings(
          startupReturn: const WebProviderSignInReturn(
            errorCode: 'access_denied',
          ),
        ),
      );

      expect(repo.takeProviderLinkReturn(), isNull);
      expect(
        repo.takeProviderSignInReturn(),
        isA<AuthProviderSignInException>().having(
          (e) => e.code,
          'code',
          'access_denied',
        ),
      );
    });

    group('belongs to the session the page came back to', () {
      test('taken under that session, it is handed out', () async {
        final repo = repoWith(
          _dio(_Bodies([_sessionAs('user-1')])),
          providerSignIn: bindings(startupReturn: linked),
        );

        expect(await repo.getSession(), isNotNull);
        expect(repo.takeProviderLinkReturn(), isA<ProviderLinkSucceeded>());
      });

      test('a page that comes back to no session drops it', () async {
        final repo = repoWith(
          _dio(_Bodies(['null'])),
          providerSignIn: bindings(startupReturn: linked),
        );

        expect(await repo.getSession(), isNull);
        expect(repo.takeProviderLinkReturn(), isNull);
      });

      test('a sign-out before it is taken drops it', () async {
        final repo = repoWith(
          _dio(_Bodies([_sessionAs('user-1')])),
          providerSignIn: bindings(startupReturn: linked),
        );

        expect(await repo.getSession(), isNotNull);
        repo.signedOutInAnotherTab();
        expect(repo.takeProviderLinkReturn(), isNull);
      });

      test('a later read as a different user drops it', () async {
        final repo = repoWith(
          _dio(_Bodies([_sessionAs('user-1'), _sessionAs('user-2')])),
          providerSignIn: bindings(startupReturn: linked),
        );

        expect(await repo.getSession(), isNotNull);
        expect(await repo.getSession(), isNotNull);
        expect(repo.takeProviderLinkReturn(), isNull);
      });

      test('a later read as the same user keeps it', () async {
        final repo = repoWith(
          _dio(_Bodies([_sessionAs('user-1')])),
          providerSignIn: bindings(startupReturn: linked),
        );

        expect(await repo.getSession(), isNotNull);
        expect(await repo.getSession(), isNotNull);
        expect(repo.takeProviderLinkReturn(), isA<ProviderLinkSucceeded>());
      });
    });

    test('is null when this page load is not a return', () {
      expect(
        repoWith(
          _dio(_Route()),
          providerSignIn: bindings(),
        ).takeProviderLinkReturn(),
        isNull,
      );
      expect(
        repoWith(
          _dio(_Route()),
          providerSignIn: bindings(
            startupReturn: const WebProviderSignInReturn(),
          ),
        ).takeProviderLinkReturn(),
        isNull,
      );
      expect(repoWith(_dio(_Route())).takeProviderLinkReturn(), isNull);
    });
  });

  group('listSignInMethods', () {
    test('GETs list-accounts and parses the rows', () async {
      final route = _Route(body: _kLiveList);
      final repo = repoWith(_dio(route));

      final methods = await repo.listSignInMethods();

      final request = route.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '$testAuthBasePath/list-accounts');
      expect(
        request.uri,
        Uri.parse('$_kOrigin$testAuthBasePath/list-accounts'),
      );
      expect(methods.single.id, '6UJgqBrNUba7ms7JrIvBYXKG5hvDXGWS');
      expect(methods.single.isPassword, isTrue);
      expect(
        methods.single.linkedAt,
        DateTime.utc(2026, 11, 19, 18, 38, 40, 649),
      );
    });

    test('a body that is not a list throws AuthServerException', () async {
      final repo = repoWith(_dio(_Route(body: '{"accounts":[]}')));

      await expectLater(
        repo.listSignInMethods(),
        throwsA(isA<AuthServerException>()),
      );
    });

    test('a body that is not JSON throws AuthServerException', () async {
      final repo = repoWith(_dio(_Route(body: '<html></html>')));

      await expectLater(
        repo.listSignInMethods(),
        throwsA(isA<AuthServerException>()),
      );
    });

    test('a transport failure throws AuthNetworkException', () async {
      final repo = repoWith(
        _dio(FailingAdapter(DioExceptionType.connectionError)),
      );

      await expectLater(
        repo.listSignInMethods(),
        throwsA(isA<AuthNetworkException>()),
      );
    });

    for (final permissive in [true, false]) {
      final shape = permissive ? 'a resolved' : 'a thrown';

      test('$shape 500 throws AuthServerException(500)', () async {
        final repo = repoWith(
          _dio(
            _Route(statusCode: 500, body: '<html></html>'),
            permissiveStatus: permissive,
          ),
        );

        await expectLater(
          repo.listSignInMethods(),
          throwsA(
            isA<AuthServerException>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
          ),
        );
      });
    }
  });

  group('unlinkSignInMethod', () {
    test('POSTs the account id to unlink-account', () async {
      final route = _Route(body: '{"status":true}');
      final repo = repoWith(_dio(route));

      await repo.unlinkSignInMethod('acc_1');

      final request = route.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '$testAuthBasePath/unlink-account');
      expect(request.data, {'accountId': 'acc_1'});
    });

    for (final permissive in [true, false]) {
      final shape = permissive ? 'a resolved' : 'a thrown';

      test('$shape 400 last-account refusal is lastSignInMethod', () async {
        final repo = repoWith(
          _dio(
            _Route(statusCode: 400, body: _kLastAccount),
            permissiveStatus: permissive,
          ),
        );

        await expectLater(
          repo.unlinkSignInMethod('acc_1'),
          throwsA(
            _linkFailure(
              ProviderLinkFailureReason.lastSignInMethod,
              code: 'FAILED_TO_UNLINK_LAST_ACCOUNT',
            ),
          ),
        );
      });
    }

    test('a transport failure throws AuthNetworkException', () async {
      final repo = repoWith(
        _dio(FailingAdapter(DioExceptionType.connectionError)),
      );

      await expectLater(
        repo.unlinkSignInMethod('acc_1'),
        throwsA(isA<AuthNetworkException>()),
      );
    });
  });

  // The provider's `url` carries its `state`, so it is never logged; only
  // outcomes and codes are.
  test('nothing a link logs contains the provider url or its state', () async {
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
      void Function(Uri url, String marker)? leavePageFor,
    }) async {
      final repo = repoWith(
        _dio(_Route(body: body)),
        providerSignIn: bindings(leavePageFor: leavePageFor),
      );
      try {
        await repo.linkProvider(_kStrategy, returnPath: _kReturnPath);
      } on AuthException {
        // The refusals are the point: each one logs.
      }
    }

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
