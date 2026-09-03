// Body-handling cases for AuthRepositoryImpl, driven through a REAL Dio.
//
// The sibling suites stub `Dio` itself, so Dio's own body handling never runs
// and they pass against the defect these cases exist for (#352): asking for a
// typed body lets Dio cast or `jsonDecode` it before the repository sees
// anything, and either failure escapes as `DioException(type: unknown)` with
// **no response attached** — so the status is gone and every one of these
// became `AuthNetworkException`, the INDETERMINATE bucket that keeps stored
// credentials on a retry-forever view.
//
// Also covers #181 (a well-formed 2xx whose FIELDS are wrong must not escape
// as a raw TypeError) and #283 (a thrown `badResponse` is a server fault, not
// a transport one).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import 'package:dio_network/src/auth/auth_repository_impl.dart';
import 'package:dio_network/src/auth/token_storage_service.dart';

import '../support/canned_adapter.dart';

class MockTokenStorage extends Mock implements TokenStorageService {}

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

Map<String, dynamic> _wireUser() => {
  'id': 'user-1',
  'name': 'testuser',
  'email': 'test@example.com',
  'emailVerified': true,
  'createdAt': '2024-01-01T00:00:00.000Z',
  'updatedAt': '2024-01-01T00:00:00.000Z',
};

Map<String, dynamic> _grantJson() => {
  'token': 'session-tok-abc',
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

const _kHtml =
    '<!doctype html><html><head><title>Sign in</title></head>'
    '<body><h1>Corporate proxy</h1></body></html>';

/// A genuine JSON session body cut off mid-document, the shape a dropped
/// connection produces.
const _kTruncatedJson = '{"session":{"id":"sess-1","token":"tok","exp';

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
        token: 'session-tok-abc',
        expiresAt: DateTime(2099).toUtc(),
        persistedAt: DateTime.utc(2026, 1, 1),
        user: AuthUser.fromJson(_wireUser()),
      ),
    );
  });

  AuthRepositoryImpl repoWith(Dio dio) {
    final repo = AuthRepositoryImpl(
      identity: _identity(),
      tokenStorage: storage,
      dio: dio,
    );
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

    test('the STATUS decides on a rejected response with an HTML body: 401 '
        'stays invalid-credentials', () async {
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
    test('HTML under application/json on a 200 is a server fault and does '
        'NOT clear stored credentials', () async {
      final repo = repoWith(cannedDio(body: _kHtml, statusCode: 200));

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
      // The whole point of #352: an intermediary's HTML must never look like
      // a rejected session, because that clears the user's credentials.
      verifyNever(() => storage.clear());
    });

    test('a truncated JSON body on a 200 does not clear credentials', () async {
      final repo = repoWith(cannedDio(body: _kTruncatedJson, statusCode: 200));

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
      verifyNever(() => storage.clear());
    });

    test('an empty 200 body is still BetterAuth\'s "no session" and DOES '
        'clear', () async {
      final repo = repoWith(cannedDio(body: '', statusCode: 200));

      expect(await repo.getSession(), isNull);
      verify(() => storage.clear()).called(1);
    });

    test(
      'a literal JSON null 200 body is "no session" and DOES clear',
      () async {
        final repo = repoWith(cannedDio(body: 'null', statusCode: 200));

        expect(await repo.getSession(), isNull);
        verify(() => storage.clear()).called(1);
      },
    );

    test('a 401 with an HTML body is still a rejected session', () async {
      final repo = repoWith(cannedDio(body: _kHtml, statusCode: 401));

      expect(await repo.getSession(), isNull);
      verify(() => storage.clear()).called(1);
    });

    test('a genuine transport failure stays indeterminate', () async {
      final repo = repoWith(unreachableDio(DioExceptionType.connectionError));

      await expectLater(
        repo.getSession(),
        throwsA(isA<AuthNetworkException>()),
      );
      verifyNever(() => storage.clear());
    });

    test(
      'a genuine sendTimeout is still a network fault, not a server one',
      () async {
        // Added to `_mapDioException`'s transport list by this PR. It used to
        // fall to the catch-all, which reached the same answer by accident;
        // now that the catch-all classifies an answered request as a server
        // fault, the accident would be an inversion.
        final repo = repoWith(unreachableDio(DioExceptionType.sendTimeout));

        await expectLater(
          repo.getSession(),
          throwsA(isA<AuthNetworkException>()),
        );
      },
    );
  });

  group(
    'malformed 2xx bodies escape as AuthException, not TypeError (#181)',
    () {
      test('a well-formed JSON object with the wrong FIELDS on the session '
          'endpoint', () async {
        final repo = repoWith(
          cannedDio(body: '{"unexpected":"shape"}', statusCode: 200),
        );

        await expectLater(
          repo.getSession(),
          throwsA(isA<AuthServerException>()),
        );
      });

      test('a bare JSON array on the session endpoint', () async {
        final repo = repoWith(cannedDio(body: '[1,2,3]', statusCode: 200));

        await expectLater(
          repo.getSession(),
          throwsA(isA<AuthServerException>()),
        );
      });

      test(
        'a well-formed JSON object with the wrong FIELDS on sign-in',
        () async {
          final repo = repoWith(
            cannedDio(body: '{"unexpected":"shape"}', statusCode: 200),
          );

          await expectLater(
            repo.signIn(email: 'a@b.c', password: 'pw'),
            throwsA(isA<AuthServerException>()),
          );
        },
      );
    },
  );

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
  });

  group('the decode window is bounded before anything is persisted (#146)', () {
    // The decode sits between the epoch guard and `_tokenStorage.store`, so
    // without a checkpoint there a sign-out landing mid-decode still reaches
    // the store — lifting the sign-out latch and re-persisting the signed-out
    // user's bearer token and PII before the post-store guard takes it back.
    // `clear()` is the single, total teardown path; a write that has to be
    // undone is not that.
    test('a sign-out mid-decode never reaches the store', () async {
      // 1 MB, so the decode is a real isolate spawn and the window is
      // milliseconds. The body is VALID JSON deliberately: the case is a
      // sign-out landing while a perfectly good session is being decoded.
      final padded = Map<String, dynamic>.from(_sessionJson())
        ..['padding'] = 'x' * (1024 * 1024);

      // The response is signalled from an interceptor rather than waited for
      // with `pumpEventQueue`, which pumps until the queue drains and so
      // over-ran the isolate under full-suite load — the sign-out then landed
      // AFTER the decode, which is a legitimate outcome, and this went red for
      // no defect. `onResponse` fires inside dio, immediately before
      // `_dio.get` returns, so one yield past it lands in the decode.
      final answered = Completer<void>();
      final dio = cannedDio(body: jsonEncode(padded), statusCode: 200)
        ..interceptors.add(
          InterceptorsWrapper(
            onResponse: (response, handler) {
              if (!answered.isCompleted) answered.complete();
              handler.next(response);
            },
          ),
        );
      final repo = repoWith(dio);

      final inFlight = repo.getSession();
      await answered.future;
      await Future<void>.delayed(Duration.zero);
      await repo.signOut();
      await inFlight.catchError((_) => null);

      // Without the checkpoint the decode resumes and stores the signed-out
      // user's bearer token and PII, only for the post-store guard to take it
      // back. `clear()` is the single, total teardown path; a write that has
      // to be undone is not that.
      //
      // Should the timing ever land the sign-out outside the window, this
      // stops exercising guard two rather than going red — it cannot fail
      // without a real defect.
      verifyNever(
        () => storage.store(
          token: any(named: 'token'),
          expiresAt: any(named: 'expiresAt'),
          persistedAt: any(named: 'persistedAt'),
          user: any(named: 'user'),
        ),
      );
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });
  });

  group('the duplicate-email probe on the THROWN path (#352)', () {
    // The only route to `_probeJson`: a rejection that arrives thrown, so the
    // body is still the raw `String` the request asked for rather than the
    // decoded map `_assertSuccess` gets. Without the probe this reports
    // "unexpected 422" instead of "that account already exists".
    test('a thrown 422 duplicate-email envelope still maps', () async {
      final repo = repoWith(
        _routingDio({
          '/sign-up/email': (
            '{"code":"USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"}',
            422,
          ),
        }),
      );

      await expectLater(
        repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
        throwsA(isA<AuthEmailAlreadyExistsException>()),
      );
    });

    test('a thrown 409 maps without reading the body at all', () async {
      final repo = repoWith(_routingDio({'/sign-up/email': (_kHtml, 409)}));

      await expectLater(
        repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
        throwsA(isA<AuthEmailAlreadyExistsException>()),
      );
    });

    test('an envelope past the probe bound is not read, so the status '
        'decides', () async {
      // Over `_probeMaxChars`. The bound is what keeps a 2 MB proxy page off
      // the main isolate, and the cost of it is exactly this: an envelope
      // this large is not treated as the duplicate-email envelope.
      final huge =
          '{"padding":"${'x' * (8 * 1024)}",'
          '"code":"USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL"}';
      final repo = repoWith(_routingDio({'/sign-up/email': (huge, 422)}));

      await expectLater(
        repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
        throwsA(isA<AuthServerException>()),
      );
    });
  });

  group('a keychain fault during clear stays inside the taxonomy (#181)', () {
    // `_clearQuietly`'s whole reason for existing. Unguarded, a
    // PlatformException from the keychain leaves getSession() raw and slips
    // past every `on AuthException` clause in AuthBloc.
    test('a 401 whose clear() throws still returns null and settles '
        'unauthenticated', () async {
      when(() => storage.clear())
          .thenThrow(PlatformException(code: 'keychain_unavailable'));
      final repo = repoWith(cannedDio(body: '', statusCode: 401));

      expect(await repo.getSession(), isNull);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('and signOut() still RETHROWS its own clear fault, which is the '
        'deliberate difference', () async {
      when(() => storage.clear())
          .thenThrow(PlatformException(code: 'keychain_unavailable'));
      final repo = repoWith(cannedDio(body: '', statusCode: 200));

      await expectLater(
        repo.signOut(),
        throwsA(isA<AuthSignOutPersistenceException>()),
      );
    });
  });

  group('the definitive/indeterminate split survives the isolate path', () {
    // #352's whole point is that a body which is not JSON is DEFINITIVE. Over
    // dio's 50 KB threshold `decodeJsonBody` parses in another isolate, so
    // this also pins that a FormatException keeps its identity across that
    // boundary — if it did not, a large captive-portal page would come back
    // as the retryable AuthNetworkException and retry forever.
    test('a >50KB non-JSON body on the session endpoint is still a server '
        'fault, not a network one', () async {
      final bigHtml = '<html>${'x' * (60 * 1024)}</html>';
      final repo = repoWith(cannedDio(body: bigHtml, statusCode: 200));

      await expectLater(repo.getSession(), throwsA(isA<AuthServerException>()));
      verifyNever(() => storage.clear());
    });

    test('and a >50KB VALID body still decodes', () async {
      final padded = Map<String, dynamic>.from(_sessionJson())
        ..['padding'] = 'x' * (60 * 1024);
      final repo = repoWith(
        cannedDio(body: jsonEncode(padded), statusCode: 200),
      );

      final result = await repo.getSession();

      expect(result?.token, 'session-tok-renewed');
    });
  });

  group('a THROWN definitive negative settles like the response path', () {
    // Native's permissive `validateStatus` normally resolves a 401 as a
    // Response, so this needs an injected Dio without it — which the class
    // accepts by design, and which is the whole premise its own catch block
    // reasons from. Web locked the same call in #180.
    test('a thrown 401 clears the stored material and returns null rather '
        'than throwing', () async {
      final repo = repoWith(
        cannedDio(body: _kHtml, statusCode: 401, permissiveStatus: false),
      );

      expect(await repo.getSession(), isNull);
      verify(() => storage.clear()).called(1);
      expect(repo.currentAuthState, isA<AuthStateUnauthenticated>());
    });

    test('a thrown 401 on the RECONCILE is not bucketed as indeterminate, so '
        'a disowned session is not kept', () async {
      // The consequence that makes this worth fixing rather than filing:
      // `_finalizeCredentialGrant` catches `on AuthException` and keeps the
      // granted session, so a rethrown definitive rejection signed the user
      // in against a session the server had just refused — the exact shape
      // that method's doc says must not happen.
      final repo = repoWith(
        _routingDio({
          '/sign-in/email': (jsonEncode(_grantJson()), 200),
          '/get-session': ('{}', 401),
        }),
      );

      await expectLater(
        repo.signIn(email: 'a@b.c', password: 'pw'),
        throwsA(isA<AuthServerException>()),
      );
      verify(() => storage.clear()).called(1);
    });

    test('a healthy reconcile is untouched by that branch', () async {
      final repo = repoWith(
        _routingDio({
          '/sign-in/email': (jsonEncode(_grantJson()), 200),
          '/get-session': (jsonEncode(_sessionJson()), 200),
        }),
      );

      final result = await repo.signIn(email: 'a@b.c', password: 'pw');

      expect(result.token, 'session-tok-renewed');
      expect(repo.currentAuthState, isA<AuthStateAuthenticated>());
    });
  });
}

/// Answers per path, so a grant can succeed while the reconcile is rejected.
/// Dio's DEFAULT `validateStatus`, so a non-2xx throws `badResponse` with the
/// response attached — the shape an injected Dio produces.
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.byPathSuffix);

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

Dio _routingDio(Map<String, (String, int)> byPathSuffix) =>
    Dio()..httpClientAdapter = _RoutingAdapter(byPathSuffix);
