import 'dart:typed_data';

import 'package:bge_test_support/domain.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:native_network/src/auth/auth_repository_impl.dart';
import 'package:native_network/src/auth/token_storage_service.dart';
import 'package:native_network/src/network/token_interceptor.dart';

class _MockTokenStorage extends Mock implements TokenStorageService {}

// A live `GET /api/auth/list-accounts` answer (task 0 probe, 2026-11-19).
const _liveList =
    '[{"accountId":"TmeL0uxivrLYLQdAZ3WdQ4sIGv8PkW5M",'
    '"providerId":"credential",'
    '"userId":"TmeL0uxivrLYLQdAZ3WdQ4sIGv8PkW5M",'
    '"createdAt":"2026-11-19T18:38:40.649Z",'
    '"updatedAt":"2026-11-19T18:38:40.649Z",'
    '"id":"6UJgqBrNUba7ms7JrIvBYXKG5hvDXGWS","scopes":[]}]';

const _lastAccount =
    '{"message":"You can\'t unlink your last '
    'account","code":"FAILED_TO_UNLINK_LAST_ACCOUNT"}';
const _notFresh =
    '{"message":"Session is not fresh","code":"SESSION_NOT_FRESH"}';

class _Sent {
  _Sent(this.method, this.path, this.authorization, this.data);

  final String method;
  final String path;
  final String? authorization;
  final Object? data;
}

class _Adapter implements HttpClientAdapter {
  _Adapter({this.status = 200, this.body = '', this.transportFailure = false});

  final int status;
  final String body;
  final bool transportFailure;
  final List<_Sent> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add(
      _Sent(
        options.method,
        options.path,
        options.headers['Authorization'] as String?,
        options.data,
      ),
    );
    if (transportFailure) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _MockTokenStorage storage;

  setUp(() {
    storage = _MockTokenStorage();
    when(() => storage.retrieve()).thenAnswer(
      (_) async => StoredSession(
        token: 'session-tok-abc',
        expiresAt: DateTime(2099).toUtc(),
        persistedAt: DateTime.utc(2026),
        user: AuthUser.fromJson({
          'id': 'user-1',
          'name': 'testuser',
          'email': 'test@example.com',
          'emailVerified': true,
          'createdAt': '2024-01-01T00:00:00.000Z',
          'updatedAt': '2024-01-01T00:00:00.000Z',
        }),
      ),
    );
  });

  ({AuthRepositoryImpl repo, _Adapter adapter}) build(
    _Adapter adapter, {
    bool permissive = true,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: testServerUrl,
        validateStatus: permissive ? (_) => true : null,
      ),
    )..httpClientAdapter = adapter;
    dio.interceptors.add(TokenInterceptor(tokenStorage: storage));
    final repo = AuthRepositoryImpl(
      identity: testServerIdentity(),
      serverUrl: testServerUrl,
      tokenStorage: storage,
      dio: dio,
    );
    addTearDown(repo.onDispose);
    return (repo: repo, adapter: adapter);
  }

  group('listSignInMethods', () {
    test('GETs list-accounts with the bearer and parses the rows', () async {
      final h = build(_Adapter(body: _liveList));

      final methods = await h.repo.listSignInMethods();

      expect(h.adapter.sent.single.method, 'GET');
      expect(h.adapter.sent.single.path, '/api/auth/list-accounts');
      expect(h.adapter.sent.single.authorization, 'Bearer session-tok-abc');
      expect(methods.single.id, '6UJgqBrNUba7ms7JrIvBYXKG5hvDXGWS');
      expect(methods.single.isPassword, isTrue);
      expect(
        methods.single.linkedAt,
        DateTime.utc(2026, 11, 19, 18, 38, 40, 649),
      );
    });

    test('a body that is not a list throws AuthServerException', () async {
      final h = build(_Adapter(body: '{"accounts":[]}'));

      expect(h.repo.listSignInMethods(), throwsA(isA<AuthServerException>()));
    });

    test('a row without an id throws AuthServerException', () async {
      final h = build(_Adapter(body: '[{"providerId":"credential"}]'));

      expect(h.repo.listSignInMethods(), throwsA(isA<AuthServerException>()));
    });

    test('a body that is not JSON throws AuthServerException', () async {
      final h = build(_Adapter(body: '<html></html>'));

      expect(h.repo.listSignInMethods(), throwsA(isA<AuthServerException>()));
    });

    test('a transport failure throws AuthNetworkException', () async {
      final h = build(_Adapter(transportFailure: true));

      expect(h.repo.listSignInMethods(), throwsA(isA<AuthNetworkException>()));
    });

    test('a 500 throws AuthServerException(500)', () async {
      final h = build(_Adapter(status: 500, body: '<html></html>'));

      expect(
        h.repo.listSignInMethods(),
        throwsA(
          isA<AuthServerException>().having((e) => e.statusCode, 's', 500),
        ),
      );
    });
  });

  group('unlinkSignInMethod', () {
    test('POSTs the account id to unlink-account', () async {
      final h = build(_Adapter(body: '{"status":true}'));

      await h.repo.unlinkSignInMethod('acc_1');

      final sent = h.adapter.sent.single;
      expect(sent.method, 'POST');
      expect(sent.path, '/api/auth/unlink-account');
      expect(sent.authorization, 'Bearer session-tok-abc');
      expect(sent.data, {'accountId': 'acc_1'});
    });

    for (final permissive in [true, false]) {
      final shape = permissive ? 'resolved' : 'thrown (strict validateStatus)';

      test('a $shape 400 last-account refusal is lastSignInMethod', () async {
        final h = build(
          _Adapter(status: 400, body: _lastAccount),
          permissive: permissive,
        );

        expect(
          h.repo.unlinkSignInMethod('acc_1'),
          throwsA(
            isA<AuthProviderLinkException>().having(
              (e) => e.reason,
              'reason',
              ProviderLinkFailureReason.lastSignInMethod,
            ),
          ),
        );
      });

      test('a $shape 403 SESSION_NOT_FRESH is needsRecentSignIn', () async {
        final h = build(
          _Adapter(status: 403, body: _notFresh),
          permissive: permissive,
        );

        expect(
          h.repo.unlinkSignInMethod('acc_1'),
          throwsA(
            isA<AuthProviderLinkException>().having(
              (e) => e.reason,
              'reason',
              ProviderLinkFailureReason.needsRecentSignIn,
            ),
          ),
        );
      });
    }

    test('a transport failure throws AuthNetworkException', () async {
      final h = build(_Adapter(transportFailure: true));

      expect(
        h.repo.unlinkSignInMethod('acc_1'),
        throwsA(isA<AuthNetworkException>()),
      );
    });
  });

  group('link', () {
    test('providerLinkSupported is false', () {
      expect(build(_Adapter()).repo.providerLinkSupported, isFalse);
    });

    test('takeProviderLinkReturn is null', () {
      expect(build(_Adapter()).repo.takeProviderLinkReturn(), isNull);
    });

    test('linkProvider fails its future with UnsupportedError, and sends '
        'nothing', () async {
      final h = build(_Adapter());

      // The future itself, not a closure: a throw at the call would fail
      // here, before the matcher sees it.
      await expectLater(
        h.repo.linkProvider(
          const OidcStrategy(
            providerId: 'authentik',
            displayName: 'Authentik',
            discoveryUrl: 'https://idp.example.com/.well-known',
            authorizationEndpoint: 'https://idp.example.com/authorize',
            appSignInEndpoint: '/api/auth/app-sign-in',
            appTokenEndpoint: '/api/auth/app-token',
          ),
          returnPath: '/settings/sign-in-methods',
        ),
        throwsUnsupportedError,
      );
      expect(h.adapter.sent, isEmpty);
    });
  });
}
