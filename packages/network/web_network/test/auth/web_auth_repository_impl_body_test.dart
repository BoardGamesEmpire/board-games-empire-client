// Body-handling cases for WebAuthRepositoryImpl, driven through a REAL Dio.
//
// The sibling suites stub `Dio` itself, so Dio's own body handling never runs
// and they pass against the defect these cases exist for (#352). See the
// native twin, `dio_network/test/auth/auth_repository_impl_body_test.dart` —
// the mechanism is identical because both repositories drive the same Dio.
//
// Also covers #283, whose home is this class: a `DioException` that carries a
// response means the server answered, and calling that a network fault told
// the user to check the one part of the system demonstrably working.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/web_auth_repository_impl.dart';

import '../support/canned_adapter.dart';

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

const _kHtml =
    '<!doctype html><html><head><title>Sign in</title></head>'
    '<body><h1>Corporate proxy</h1></body></html>';

Map<String, dynamic> _grantJson() => {
  'token': 'session-tok-web',
  'user': {
    'id': 'user-1',
    'name': 'webuser',
    'email': 'web@example.com',
    'emailVerified': true,
    'createdAt': '2024-01-01T00:00:00.000Z',
    'updatedAt': '2024-01-01T00:00:00.000Z',
  },
};

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

const _kTruncatedJson = '{"session":{"id":"sess-1","token":"tok","exp';

void main() {
  WebAuthRepositoryImpl repoWith(Dio dio) {
    final repo = WebAuthRepositoryImpl(identity: _identity(), dio: dio);
    addTearDown(repo.onDispose);
    return repo;
  }

  group('signIn() body handling (#352)', () {
    test('HTML under text/html on a 200 is a server fault, not a network '
        'one', () async {
      final repo = repoWith(
        cannedDio(body: _kHtml, statusCode: 200, contentType: 'text/html'),
      );

      await expectLater(
        repo.signIn(email: 'a@b.c', password: 'pw'),
        throwsA(isA<AuthServerException>()),
      );
    });

    test(
      'HTML served under application/json on a 200 is a server fault',
      () async {
        final repo = repoWith(cannedDio(body: _kHtml, statusCode: 200));

        await expectLater(
          repo.signIn(email: 'a@b.c', password: 'pw'),
          throwsA(isA<AuthServerException>()),
        );
      },
    );

    test('a truncated JSON body on a 200 is a server fault', () async {
      final repo = repoWith(cannedDio(body: _kTruncatedJson, statusCode: 200));

      await expectLater(
        repo.signIn(email: 'a@b.c', password: 'pw'),
        throwsA(isA<AuthServerException>()),
      );
    });

    test('the STATUS decides: a 401 with an HTML body stays '
        'invalid-credentials', () async {
      final repo = repoWith(cannedDio(body: _kHtml, statusCode: 401));

      await expectLater(
        repo.signIn(email: 'a@b.c', password: 'pw'),
        throwsA(isA<AuthInvalidCredentialsException>()),
      );
    });

    test('a 500 with an HTML body keeps its status', () async {
      final repo = repoWith(cannedDio(body: _kHtml, statusCode: 500));

      await expectLater(
        repo.signIn(email: 'a@b.c', password: 'pw'),
        throwsA(
          isA<AuthServerException>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
    });

    test('a 422 duplicate-email envelope still maps, now that the body '
        'arrives undecoded', () async {
      final repo = repoWith(
        cannedDio(
          body: '{"code":"USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"}',
          statusCode: 422,
        ),
      );

      await expectLater(
        repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
        throwsA(isA<AuthEmailAlreadyExistsException>()),
      );
    });
  });

  group('getSession() body handling (#352)', () {
    test('HTML under application/json on a 200 is a server fault, not '
        '"can\'t reach the server"', () async {
      final repo = repoWith(cannedDio(body: _kHtml, statusCode: 200));

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
      // Not unauthenticated: an intermediary's HTML is not a rejected
      // session, and must not present as one.
      expect(repo.currentAuthState, isNot(isA<AuthStateUnauthenticated>()));
    });

    test('a truncated JSON body on a 200 is a server fault', () async {
      final repo = repoWith(cannedDio(body: _kTruncatedJson, statusCode: 200));

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
    });

    test('an empty 200 body is still BetterAuth\'s "no session"', () async {
      final repo = repoWith(cannedDio(body: '', statusCode: 200));

      expect(await repo.getSession(), isNull);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a literal JSON null 200 body is "no session"', () async {
      final repo = repoWith(cannedDio(body: 'null', statusCode: 200));

      expect(await repo.getSession(), isNull);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a 401 with an HTML body is still a rejected session', () async {
      final repo = repoWith(cannedDio(body: _kHtml, statusCode: 401));

      expect(await repo.getSession(), isNull);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a bodiless 502 is INDETERMINATE, not a sign-out (#180)', () async {
      final repo = repoWith(cannedDio(body: '', statusCode: 502));

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
      expect(repo.currentAuthState, isNot(isA<AuthStateUnauthenticated>()));
    });

    test('a genuine transport failure stays indeterminate', () async {
      final repo = repoWith(unreachableDio(DioExceptionType.connectionError));

      await expectLater(
        repo.getSession(),
        throwsA(isA<AuthNetworkException>()),
      );
    });
  });

  group('malformed 2xx bodies stay inside the taxonomy (#181)', () {
    test('a well-formed JSON object with the wrong FIELDS on the session '
        'endpoint', () async {
      final repo = repoWith(
        cannedDio(body: '{"unexpected":"shape"}', statusCode: 200),
      );

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
    });

    test('a bare JSON array on the session endpoint', () async {
      final repo = repoWith(cannedDio(body: '[1,2,3]', statusCode: 200));

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
    });
  });

  group('a thrown badResponse is a server fault, not transport (#283)', () {
    test('a 404 from a Dio whose validateStatus is not permissive', () async {
      final repo = repoWith(
        cannedDio(body: _kHtml, statusCode: 404, permissiveStatus: false),
      );

      await expectLater(
        repo.getSession(),
        throwsA(
          isA<AuthServerException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('a 400 on sign-in', () async {
      final repo = repoWith(
        cannedDio(body: '{}', statusCode: 400, permissiveStatus: false),
      );

      await expectLater(
        repo.signIn(email: 'a@b.c', password: 'pw'),
        throwsA(isA<AuthServerException>()),
      );
    });

    test('a genuine sendTimeout is still a network fault', () async {
      final repo = repoWith(unreachableDio(DioExceptionType.sendTimeout));

      await expectLater(
        repo.getSession(),
        throwsA(isA<AuthNetworkException>()),
      );
    });
  });

  group('the reconcile fallback covers every indeterminate fault', () {
    // The malformed-2xx case is already pinned in
    // `web_auth_repository_impl_test.dart` (#180 D9). These add the status
    // classes around it, driven through a real Dio.
    //
    // Indeterminate means this client could not DETERMINE whether a session
    // exists — "the response is definitively broken" is not "the session is
    // definitively absent".
    test('a 5xx reconcile keeps the granted session', () async {
      final repo = repoWith(
        _routingDio({
          '/sign-in/email': (jsonEncode(_grantJson()), 200),
          '/get-session': ('{}', 503),
        }),
      );

      final result = await repo.signIn(email: 'a@b.c', password: 'pw');

      expect(result.user.id, 'user-1');
      expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
    });

    test('a 4xx reconcile keeps it — #297 reads a 404 on a fixed route as a '
        'deployment fault, not a rejection', () async {
      final repo = repoWith(
        _routingDio({
          '/sign-in/email': (jsonEncode(_grantJson()), 200),
          '/get-session': ('{}', 404),
        }),
      );

      final result = await repo.signIn(email: 'a@b.c', password: 'pw');

      expect(result.user.id, 'user-1');
      expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
    });
  });

  group('the duplicate-email probe on the THROWN path (#352)', () {
    // The only route to `_probeJson`: a rejection that arrives thrown, so the
    // body is still the raw `String` the request asked for.
    test('a thrown 422 duplicate-email envelope still maps', () async {
      final repo = repoWith(
        _routingDio({
          '/sign-up/email': (
            '{"code":"USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"}',
            422,
          ),
        }, permissive: false),
      );

      await expectLater(
        repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
        throwsA(isA<AuthEmailAlreadyExistsException>()),
      );
    });

    test('a thrown 409 on the SESSION endpoint is a server fault, not a '
        'duplicate email', () async {
      final repo = repoWith(
        _routingDio({'/get-session': ('{}', 409)}, permissive: false),
      );

      await expectLater(
        repo.getSession(),
        throwsA(
          isA<AuthServerException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });

    test('an envelope past the probe bound is not read, so the status '
        'decides', () async {
      final huge =
          '{"padding":"${'x' * (8 * 1024)}",'
          '"code":"USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"}';
      final repo = repoWith(
        _routingDio({'/sign-up/email': (huge, 422)}, permissive: false),
      );

      await expectLater(
        repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
        throwsA(isA<AuthServerException>()),
      );
    });
  });

  group('the decode is a suspension point the epoch has to bound (#146)', () {
    // Regression for a window this PR opened: moving the decode below the
    // first epoch guard put an await between that guard and the state
    // emission it protects. A sign-out landing there was ignored and the
    // session re-asserted after the user had ended it.
    test(
      'a sign-out is never overtaken by a session response still decoding',
      () async {
        // Well over dio's 50 KB threshold, so `decodeJsonBody` offloads to a
        // real isolate and the window is milliseconds rather than microtasks.
        final padded = Map<String, dynamic>.from(_sessionJson())
          ..['padding'] = 'x' * (256 * 1024);
        final repo = repoWith(
          cannedDio(body: jsonEncode(padded), statusCode: 200),
        );

        final inFlight = repo.getSession();
        await pumpEventQueue();
        await repo.signOut();
        // Swallow the result: which of the two guards fires depends on where
        // the sign-out lands, and both are correct outcomes.
        await inFlight.catchError((_) => null);

        // The SAFETY property, asserted instead of one interleaving, because
        // the exact landing point is not controllable from here — nothing in
        // dio's pipeline can hook the decode, which happens after it returns.
        // Stated this way the test can only ever fail for a real defect: the
        // user signed out, so whatever the ordering, the repository must not
        // be left authenticated. Without the second checkpoint this fails
        // whenever the sign-out lands mid-decode, which the 256 KB body makes
        // the common case.
        expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
      },
    );
  });

  group('an unreadable grant body defers to the reconcile, never vetoes the '
      'sign-in', () {
    // Web's cookie is already set by the grant response, so the envelope is a
    // convenience and the reconcile is the authority — `_grantOrNull` and
    // `_reconcileCredentialGrant` are both built on that. A body that is not
    // JSON at all must behave like one whose fields are wrong, which already
    // recovered.
    test('a non-JSON sign-in body still signs in when the session endpoint '
        'answers', () async {
      final repo = repoWith(
        _routingDio({
          '/sign-in/email': (_kHtml, 200),
          '/get-session': (jsonEncode(_sessionJson()), 200),
        }),
      );

      final result = await repo.signIn(email: 'a@b.c', password: 'pw');

      expect(result.user.id, 'user-1');
      expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
    });

    test('but a non-JSON body the reconcile cannot rescue still surfaces the '
        'reconcile\'s own failure', () async {
      final repo = repoWith(
        _routingDio({
          '/sign-in/email': (_kHtml, 200),
          '/get-session': (_kHtml, 200),
        }),
      );

      await expectLater(
        repo.signIn(email: 'a@b.c', password: 'pw'),
        throwsA(isA<AuthServerException>()),
      );
    });
  });
}

/// A [CannedAdapter] that answers per path, so a sign-in can fail its grant
/// body while the session endpoint still answers well — the case
/// `_requireGrantBody`'s leniency exists for.
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.byPathSuffix);

  /// Suffix → (body, status). Every route is answered as
  /// `application/json`, which is the content type these cases turn on:
  /// the point is a body that LIES about its type, so making it
  /// per-route would only let a case understate the bug.
  final Map<String, (String, int)> byPathSuffix;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    for (final entry in byPathSuffix.entries) {
      if (options.path.endsWith(entry.key)) {
        return ResponseBody.fromString(
          entry.value.$1,
          entry.value.$2,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
    }
    throw StateError('no canned answer for ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

Dio _routingDio(
  Map<String, (String, int)> byPathSuffix, {
  bool permissive = true,
}) =>
    Dio(BaseOptions(validateStatus: permissive ? (_) => true : null))
      ..httpClientAdapter = _RoutingAdapter(byPathSuffix);
