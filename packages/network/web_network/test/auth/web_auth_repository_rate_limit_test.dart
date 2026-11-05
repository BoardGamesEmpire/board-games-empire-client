// A 429 on sign-in and sign-up is a rate limit with its wait (#559).
//
// The web twin of `dio_network/test/auth/auth_repository_rate_limit_test.dart`:
// a resolved and a thrown 429, through a real Dio. `parseRetryAfter` is
// unit-tested there; it is one shared function.

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/web_auth_repository_impl.dart';

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

/// Answers every request with [statusCode], [body] and any [headers].
///
/// `cannedDio` cannot attach a response header, and the wait is the point.
class _HeaderAdapter implements HttpClientAdapter {
  _HeaderAdapter({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      for (final entry in headers.entries) entry.key: [entry.value],
    },
  );

  @override
  void close({bool force = false}) {}
}

Dio _dio({
  String body = '{"code":"RATE_LIMITED","message":"slow down"}',
  Map<String, String> headers = const {},
  bool permissiveStatus = true,
}) =>
    Dio(
        BaseOptions(
          validateStatus: permissiveStatus ? (_) => true : null,
          followRedirects: false,
        ),
      )
      ..httpClientAdapter = _HeaderAdapter(
        statusCode: 429,
        body: body,
        headers: headers,
      );

Matcher _rateLimited(Duration? retryAfter) => isA<AuthRateLimitedException>()
    .having((e) => e.retryAfter, 'retryAfter', retryAfter);

void main() {
  WebAuthRepositoryImpl repoWith(Dio dio) {
    final repo = WebAuthRepositoryImpl(identity: _identity(), dio: dio);
    addTearDown(repo.onDispose);
    return repo;
  }

  for (final permissive in [true, false]) {
    final shape = permissive
        ? 'a resolved 429'
        : 'a thrown 429 (strict validateStatus Dio)';

    group(shape, () {
      test(
        'with X-Retry-After 7 throws AuthRateLimitedException(7 s)',
        () async {
          final repo = repoWith(
            _dio(headers: {'x-retry-after': '7'}, permissiveStatus: permissive),
          );

          await expectLater(
            repo.signIn(email: 'a@b.c', password: 'pw'),
            throwsA(_rateLimited(const Duration(seconds: 7))),
          );
        },
      );

      test('without X-Retry-After has a null retryAfter', () async {
        final repo = repoWith(_dio(permissiveStatus: permissive));

        await expectLater(
          repo.signIn(email: 'a@b.c', password: 'pw'),
          throwsA(_rateLimited(null)),
        );
      });

      test('with X-Retry-After "soon" has a null retryAfter', () async {
        final repo = repoWith(
          _dio(
            headers: {'x-retry-after': 'soon'},
            permissiveStatus: permissive,
          ),
        );

        await expectLater(
          repo.signIn(email: 'a@b.c', password: 'pw'),
          throwsA(_rateLimited(null)),
        );
      });

      test('without the RATE_LIMITED code is still a rate limit', () async {
        final repo = repoWith(
          _dio(
            body: '{"message":"x"}',
            headers: {'x-retry-after': '3'},
            permissiveStatus: permissive,
          ),
        );

        await expectLater(
          repo.signIn(email: 'a@b.c', password: 'pw'),
          throwsA(_rateLimited(const Duration(seconds: 3))),
        );
      });

      test('on sign-up maps the same way', () async {
        final repo = repoWith(
          _dio(headers: {'x-retry-after': '7'}, permissiveStatus: permissive),
        );

        await expectLater(
          repo.signUp(email: 'a@b.c', password: 'pw', username: 'u'),
          throwsA(_rateLimited(const Duration(seconds: 7))),
        );
      });
    });
  }

  test(
    'a thrown 429 on the session read is not a rate-limited grant',
    () async {
      final repo = repoWith(
        _dio(headers: {'x-retry-after': '7'}, permissiveStatus: false),
      );

      await expectLater(
        repo.getSession(),
        throwsA(
          isA<AuthServerException>().having((e) => e.statusCode, 'status', 429),
        ),
      );
    },
  );
}
