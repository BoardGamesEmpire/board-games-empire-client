import 'dart:convert';

import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:dio_network/src/api_key/api_key_json.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

const _secret = 'bge_SECRETSECRETSECRET0123456789';

Map<String, dynamic> _keyJson({
  String id = 'k_1',
  Object? name = 'CI',
  Object? start = 'bge_ab',
  List<Map<String, dynamic>> scopes = const [
    {'slug': 'read:game', 'resourceId': null},
  ],
  Object? expiresAt = '2027-02-22T10:00:00.000Z',
  bool enabled = true,
  Object? lastUsedAt,
  String createdAt = '2026-11-24T10:00:00.000Z',
}) => {
  'id': id,
  'name': name,
  'start': start,
  'scopes': scopes,
  'expiresAt': expiresAt,
  'enabled': enabled,
  'lastUsedAt': lastUsedAt,
  'createdAt': createdAt,
};

/// Nest's rendering of a coded refusal, `{ statusCode, error, message, code,
/// ...fields }`.
Map<String, dynamic> _coded(
  int status,
  String code, [
  Map<String, dynamic> fields = const {},
]) => {
  'statusCode': status,
  'error': 'Unprocessable Entity',
  'message': 'The server says no.',
  'code': code,
  ...fields,
};

void main() {
  late ScriptedServer server;
  late ApiKeyRemoteDataSource remote;

  setUp(() {
    server = ScriptedServer();
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = server;
    remote = ApiKeyRemoteDataSourceImpl(dio);
  });

  group('fetchGrantable', () {
    test('parses permissions with their risk levels', () async {
      server.json('GET', '/api/api-keys/grantable', {
        'permissions': [
          {
            'slug': 'read:game',
            'description': 'See games',
            'riskLevel': 'Low',
            'pinnable': true,
          },
          {
            'slug': 'delete:user',
            'description': 'Remove users',
            'riskLevel': 'Critical',
            'pinnable': false,
          },
          {
            'slug': 'odd',
            'description': 'Something new',
            'riskLevel': 'Severe',
            'pinnable': false,
          },
        ],
      });

      final permissions = await remote.fetchGrantable();

      expect(permissions.map((p) => p.slug), [
        'read:game',
        'delete:user',
        'odd',
      ]);
      expect(permissions[0].riskLevel, RiskLevel.low);
      expect(permissions[0].pinnable, isTrue);
      expect(permissions[0].description, 'See games');
      expect(permissions[1].riskLevel, RiskLevel.critical);
      expect(permissions[2].riskLevel, RiskLevel.unknown);
    });
  });

  group('fetchPage', () {
    test('sends page and limit and reads the apiKeys envelope', () async {
      server.json('GET', '/api/api-keys', {
        'apiKeys': [_keyJson(), _keyJson(id: 'k_2')],
        'pagination': {
          'page': 2,
          'limit': 10,
          'total': 12,
          'totalPages': 2,
          'hasMore': false,
        },
      });

      final page = await remote.fetchPage(page: 2, limit: 10);

      final sent = server.requestsTo('GET', '/api/api-keys').single;
      expect(sent.queryParameters, {'page': 2, 'limit': 10});
      expect(page.items.map((k) => k.id), ['k_1', 'k_2']);
      expect(page.meta.total, 12);
    });

    test('refuses a limit over 50 before sending', () async {
      await expectLater(
        remote.fetchPage(limit: 51),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        remote.fetchPage(page: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });
  });

  group('fetch', () {
    test('reads the apiKey envelope from the encoded id', () async {
      server.json('GET', '/api/api-keys/a%2Fb', {
        'apiKey': _keyJson(id: 'a/b'),
      });

      final key = await remote.fetch('a/b');

      expect(key.id, 'a/b');
      expect(server.requests.single.path, '/api/api-keys/a%2Fb');
    });

    test('refuses an empty id before sending', () async {
      await expectLater(remote.fetch(''), throwsA(isA<ArgumentError>()));
      expect(server.requests, isEmpty);
    });
  });

  group('apiKeyFromJson', () {
    test('keeps UTC dates and pins, and tolerates missing optionals', () {
      final full = apiKeyFromJson(
        _keyJson(
          scopes: [
            {'slug': 'read:game', 'resourceId': 'g_1'},
            {'slug': 'read:event'},
          ],
          lastUsedAt: '2026-11-25T08:30:00.000Z',
        ),
      );

      expect(full.createdAt, DateTime.utc(2026, 11, 24, 10));
      expect(full.createdAt.isUtc, isTrue);
      expect(full.expiresAt, DateTime.utc(2027, 2, 22, 10));
      expect(full.lastUsedAt, DateTime.utc(2026, 11, 25, 8, 30));
      expect(full.scopes[0].resourceId, 'g_1');
      expect(full.scopes[0].pinned, isTrue);
      expect(full.scopes[1].resourceId, isNull);

      final bare = apiKeyFromJson({
        'id': 'k_2',
        'scopes': <Object?>[],
        'enabled': false,
        'createdAt': '2026-11-24T10:00:00.000Z',
      });
      expect(bare.name, isNull);
      expect(bare.start, isNull);
      expect(bare.expiresAt, isNull);
      expect(bare.lastUsedAt, isNull);
      expect(bare.enabled, isFalse);
    });

    test('a body that breaks the contract is permanent', () async {
      server.json('GET', '/api/api-keys/k_1', {
        'apiKey': _keyJson()..remove('scopes'),
      });

      await expectLater(
        remote.fetch('k_1'),
        throwsA(isA<ApiKeyPermanentException>()),
      );
    });
  });

  group('create', () {
    void answerCreate() => server.json('POST', '/api/api-keys', {
      'message': 'created',
      'apiKey': _keyJson(),
      'secret': _secret,
    }, status: 201);

    test(
      'with scopes sends name, scopes and expiresInDays, and no preset',
      () async {
        answerCreate();

        await remote.create(
          const ApiKeyCreate(
            name: ' CI ',
            grant: ApiKeyScopesGrant([
              ApiKeyScope(slug: 'read:game'),
              ApiKeyScope(slug: 'read:event', resourceId: 'e_1'),
            ]),
            expiresInDays: 30,
          ),
        );

        expect(server.requests.single.data, {
          'name': 'CI',
          'scopes': [
            {'slug': 'read:game'},
            {'slug': 'read:event', 'resourceId': 'e_1'},
          ],
          'expiresInDays': 30,
        });
      },
    );

    test('with everything sends preset and no scopes', () async {
      answerCreate();

      await remote.create(
        const ApiKeyCreate(name: 'all', grant: ApiKeyEverythingGrant()),
      );

      expect(server.requests.single.data, {
        'name': 'all',
        'preset': 'everything',
        'expiresInDays': 90,
      });
    });

    test('sends confirmCritical only when true', () async {
      answerCreate();

      await remote.create(
        const ApiKeyCreate(name: 'a', grant: ApiKeyEverythingGrant()),
      );
      await remote.create(
        const ApiKeyCreate(
          name: 'a',
          grant: ApiKeyEverythingGrant(),
          confirmCritical: true,
        ),
      );

      final bodies = server.requests.map((r) => r.data! as Map).toList();
      expect(bodies[0].containsKey('confirmCritical'), isFalse);
      expect(bodies[1]['confirmCritical'], isTrue);
    });

    test('toJson omits a null resourceId and keeps a set one', () {
      final unpinned = apiKeyScopeToJson(const ApiKeyScope(slug: 'read:game'));
      final pinned = apiKeyScopeToJson(
        const ApiKeyScope(slug: 'read:game', resourceId: 'g_1'),
      );

      expect(unpinned.containsKey('resourceId'), isFalse);
      expect(unpinned, {'slug': 'read:game'});
      expect(pinned, {'slug': 'read:game', 'resourceId': 'g_1'});
    });

    test(
      'reads the secret once, and its text never reaches toString',
      () async {
        answerCreate();

        final created = await remote.create(
          const ApiKeyCreate(name: 'a', grant: ApiKeyEverythingGrant()),
        );

        expect(created.secret, _secret);
        expect(created.apiKey.id, 'k_1');
        expect(created.toString(), isNot(contains(_secret)));
      },
    );

    test('a 2xx without a secret is permanent and names no body', () async {
      server.json('POST', '/api/api-keys', {
        'message': 'created',
        'apiKey': _keyJson(),
        'secret': 42,
      });

      await expectLater(
        remote.create(
          const ApiKeyCreate(name: 'a', grant: ApiKeyEverythingGrant()),
        ),
        throwsA(isA<ApiKeyPermanentException>()),
      );
    });

    test('refuses what the server would refuse, before sending', () async {
      const grant = ApiKeyEverythingGrant();
      final bad = <ApiKeyCreate>[
        const ApiKeyCreate(name: '   ', grant: grant),
        ApiKeyCreate(name: 'x' * 33, grant: grant),
        const ApiKeyCreate(name: 'a', grant: grant, expiresInDays: 0),
        const ApiKeyCreate(name: 'a', grant: grant, expiresInDays: 366),
        const ApiKeyCreate(
          name: 'a',
          grant: ApiKeyScopesGrant([
            ApiKeyScope(slug: 'read:game', resourceId: ''),
          ]),
        ),
        const ApiKeyCreate(
          name: 'a',
          grant: ApiKeyScopesGrant([ApiKeyScope(slug: '')]),
        ),
      ];

      for (final request in bad) {
        await expectLater(
          remote.create(request),
          throwsA(isA<ArgumentError>()),
        );
      }
      expect(server.requests, isEmpty);
    });

    test('measures the name trimmed, in UTF-16 units', () async {
      answerCreate();

      await remote.create(
        ApiKeyCreate(
          name: '  ${'x' * 32}  ',
          grant: const ApiKeyEverythingGrant(),
        ),
      );
      expect(server.requests, hasLength(1));

      // A surrogate pair counts two, as it does for better-auth.
      await expectLater(
        remote.create(
          ApiKeyCreate(name: '😀' * 17, grant: const ApiKeyEverythingGrant()),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('update', () {
    test('sends only the fields set', () async {
      server.json('PATCH', '/api/api-keys/k_1', {
        'message': 'updated',
        'apiKey': _keyJson(name: 'ci'),
      });

      final key = await remote.update('k_1', const ApiKeyPatch(name: 'ci'));

      expect(server.requests.single.data, {'name': 'ci'});
      expect(key.name, 'ci');
    });

    test('sends every field that is set, scopes with their pins', () async {
      server.json('PATCH', '/api/api-keys/k_1', {
        'message': 'updated',
        'apiKey': _keyJson(),
      });

      await remote.update(
        'k_1',
        const ApiKeyPatch(
          name: ' ci ',
          enabled: false,
          scopes: [
            ApiKeyScope(slug: 'read:game', resourceId: 'g_1'),
            ApiKeyScope(slug: 'read:event'),
          ],
          expiresInDays: 7,
          confirmCritical: true,
        ),
      );

      expect(server.requests.single.data, {
        'name': 'ci',
        'enabled': false,
        'scopes': [
          {'slug': 'read:game', 'resourceId': 'g_1'},
          {'slug': 'read:event'},
        ],
        'expiresInDays': 7,
        'confirmCritical': true,
      });
    });

    test('an empty scopes list is sent, because it is a change', () async {
      server.json('PATCH', '/api/api-keys/k_1', {
        'message': 'updated',
        'apiKey': _keyJson(scopes: const []),
      });

      await remote.update('k_1', const ApiKeyPatch(scopes: []));

      expect(server.requests.single.data, {'scopes': <Object?>[]});
    });

    test(
      'with an empty patch throws ArgumentError and sends nothing',
      () async {
        await expectLater(
          remote.update('k_1', const ApiKeyPatch()),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          remote.update('k_1', const ApiKeyPatch(confirmCritical: true)),
          throwsA(isA<ArgumentError>()),
        );
        expect(server.requests, isEmpty);
      },
    );

    test('refuses an invalid name, expiry or id before sending', () async {
      await expectLater(
        remote.update('k_1', const ApiKeyPatch(name: '')),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        remote.update('k_1', const ApiKeyPatch(expiresInDays: 400)),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        remote.update('..', const ApiKeyPatch(name: 'a')),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });
  });

  group('delete', () {
    test('sends DELETE to the encoded id and reads no body', () async {
      // An empty body would break a read, so this pins `readBody: false`.
      server.on(
        'DELETE',
        '/api/api-keys/a%2Fb',
        (_) => const ScriptedResponse(''),
      );

      await remote.delete('a/b');

      final sent = server.requests.single;
      expect(sent.method, 'DELETE');
      expect(sent.path, '/api/api-keys/a%2Fb');
    });
  });

  group('refusals', () {
    Future<Object> thrownBy(
      int status,
      Map<String, dynamic> body,
      Future<void> Function() call,
    ) async {
      server
        ..on(
          'POST',
          '/api/api-keys',
          (_) => ScriptedResponse.json(body, status: status),
        )
        ..on(
          'GET',
          '/api/api-keys/k_1',
          (_) => ScriptedResponse.json(body, status: status),
        );
      try {
        await call();
      } on Object catch (error) {
        return error;
      }
      fail('did not throw');
    }

    Future<Object> create(int status, Map<String, dynamic> body) => thrownBy(
      status,
      body,
      () => remote.create(
        const ApiKeyCreate(name: 'a', grant: ApiKeyEverythingGrant()),
      ),
    );

    test('403 API_KEY_NEEDS_RECENT_SIGN_IN', () async {
      final error = await create(
        403,
        _coded(403, 'API_KEY_NEEDS_RECENT_SIGN_IN'),
      );
      expect(error, isA<ApiKeyNeedsRecentSignInException>());
      expect((error as ApiKeyRemoteException).statusCode, 403);
      expect(error.apiMessage, 'The server says no.');
    });

    test('403 API_KEY_SESSION_REQUIRED', () async {
      final error = await create(403, _coded(403, 'API_KEY_SESSION_REQUIRED'));
      expect(error, isA<ApiKeySessionRequiredException>());
    });

    test('404 API_KEY_NOT_FOUND on a row route', () async {
      final error = await thrownBy(
        404,
        _coded(404, 'API_KEY_NOT_FOUND'),
        () => remote.fetch('k_1'),
      );
      expect(error, isA<ApiKeyNotFoundException>());
      expect(
        (error as ApiKeyRemoteException).apiMessage,
        'The server says no.',
      );
    });

    test('404 on update and delete is not found too', () async {
      server
        ..json(
          'PATCH',
          '/api/api-keys/k_1',
          _coded(404, 'API_KEY_NOT_FOUND'),
          status: 404,
        )
        ..json(
          'DELETE',
          '/api/api-keys/k_2',
          _coded(404, 'API_KEY_NOT_FOUND'),
          status: 404,
        );

      await expectLater(
        remote.update('k_1', const ApiKeyPatch(name: 'a')),
        throwsA(isA<ApiKeyNotFoundException>()),
      );
      await expectLater(
        remote.delete('k_2'),
        throwsA(isA<ApiKeyNotFoundException>()),
      );
    });

    test(
      'an unrouted 404 with its own code is transient, not "not found"',
      () async {
        final error = await thrownBy(
          404,
          _coded(404, 'ROUTE_NOT_FOUND'),
          () => remote.fetch('k_1'),
        );
        expect(error, isA<ApiKeyTransientException>());
      },
    );

    test('422 API_KEY_CRITICAL_NEEDS_CONFIRMATION', () async {
      final error = await create(
        422,
        _coded(422, 'API_KEY_CRITICAL_NEEDS_CONFIRMATION'),
      );
      expect(error, isA<ApiKeyCriticalNeedsConfirmationException>());
    });

    test('422 API_KEY_SCOPE_NOT_GRANTABLE names the slug', () async {
      final error = await create(
        422,
        _coded(422, 'API_KEY_SCOPE_NOT_GRANTABLE', {'slug': 'delete:user'}),
      );
      expect(error, isA<ApiKeyScopeNotGrantableException>());
      expect((error as ApiKeyScopeNotGrantableException).slug, 'delete:user');
    });

    test('422 API_KEY_SCOPE_NOT_PINNABLE names the slug', () async {
      final error = await create(
        422,
        _coded(422, 'API_KEY_SCOPE_NOT_PINNABLE', {'slug': 'create:game'}),
      );
      expect(error, isA<ApiKeyScopeNotPinnableException>());
      expect((error as ApiKeyScopeNotPinnableException).slug, 'create:game');
    });

    test('422 API_KEY_EXPIRY_OUT_OF_RANGE carries min and max', () async {
      final error = await create(
        422,
        _coded(422, 'API_KEY_EXPIRY_OUT_OF_RANGE', {'min': 1, 'max': 365}),
      );
      expect(error, isA<ApiKeyExpiryOutOfRangeException>());
      expect((error as ApiKeyExpiryOutOfRangeException).min, 1);
      expect(error.max, 365);
    });

    test('a slug, min or max of the wrong type is left null', () async {
      final slug = await create(
        422,
        _coded(422, 'API_KEY_SCOPE_NOT_GRANTABLE', {'slug': 7}),
      );
      expect((slug as ApiKeyScopeNotGrantableException).slug, isNull);

      final range = await create(
        422,
        _coded(422, 'API_KEY_EXPIRY_OUT_OF_RANGE', {'min': '1'}),
      );
      expect((range as ApiKeyExpiryOutOfRangeException).min, isNull);
      expect(range.max, isNull);
    });

    test('422 API_KEY_SCOPES_OR_PRESET is permanent', () async {
      final error = await create(422, _coded(422, 'API_KEY_SCOPES_OR_PRESET'));
      expect(error, isA<ApiKeyPermanentException>());
      expect(
        (error as ApiKeyRemoteException).apiMessage,
        'The server says no.',
      );
    });

    test('a 400 validation error is permanent', () async {
      final error = await create(400, {
        'statusCode': 400,
        'error': 'Bad Request',
        'message': 'name must be shorter',
      });
      expect(error, isA<ApiKeyPermanentException>());
      expect((error as ApiKeyRemoteException).statusCode, 400);
    });

    test("a 400 with a message list keeps the server's words", () async {
      final error = await create(400, {
        'statusCode': 400,
        'error': 'Bad Request',
        'message': ['name must be shorter', 'expiresInDays must be an integer'],
      });
      expect(error, isA<ApiKeyPermanentException>());
      expect(
        (error as ApiKeyRemoteException).apiMessage,
        'name must be shorter\nexpiresInDays must be an integer',
      );
    });

    test('any other enveloped 4xx is permanent, with its message', () async {
      final error = await create(409, _coded(409, 'SOMETHING_ELSE'));
      expect(error, isA<ApiKeyPermanentException>());
      expect(
        (error as ApiKeyRemoteException).apiMessage,
        'The server says no.',
      );
    });

    test('an unenveloped 422 is permanent, not coded', () async {
      final error = await create(422, {
        'code': 'API_KEY_SCOPE_NOT_GRANTABLE',
        'slug': 'x',
      });
      expect(error, isA<ApiKeyPermanentException>());
      expect((error as ApiKeyRemoteException).apiMessage, isNull);
    });

    test('an unenveloped 403 is the gateway, so transient', () async {
      final error = await create(403, {'code': 'API_KEY_SESSION_REQUIRED'});
      expect(error, isA<ApiKeyTransientException>());
    });

    test('a 5xx and a lost connection are transient', () async {
      final fiveHundred = await create(503, {'message': 'down'});
      expect(fiveHundred, isA<ApiKeyTransientException>());

      server.drop('POST', '/api/api-keys');
      await expectLater(
        remote.create(
          const ApiKeyCreate(name: 'a', grant: ApiKeyEverythingGrant()),
        ),
        throwsA(isA<ApiKeyTransientException>()),
      );
    });

    test(
      'no failure of a create carries the request or response body',
      () async {
        server.json('POST', '/api/api-keys', {
          'message': 'created',
          'apiKey': {'id': 7},
          'secret': _secret,
        });

        try {
          await remote.create(
            const ApiKeyCreate(name: 'a', grant: ApiKeyEverythingGrant()),
          );
          fail('did not throw');
        } on ApiKeyRemoteException catch (error) {
          expect(error.message, isNot(contains(_secret)));
          expect(error.toString(), isNot(contains(_secret)));
          expect(jsonEncode(error.message), isNot(contains(_secret)));
        }
      },
    );
  });
}
