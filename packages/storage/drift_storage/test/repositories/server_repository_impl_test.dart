import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/repositories/server_repository_impl.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

const _kBgeServerId = '550e8400-e29b-41d4-a716-446655440000';
const _kServerUrl = 'https://api.example.com';

ServerIdentity _makeIdentity({
  String serverId = _kBgeServerId,
  String issuer = _kServerUrl,
}) => ServerIdentity(
  serverId: serverId,
  issuer: issuer,
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$issuer/api/auth/device',
  authBasePath: '$issuer/api/auth',
  sessionEndpoint: '$issuer/api/auth/get-session',
  signOutEndpoint: '$issuer/api/auth/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
);

Future<ServerConfig> _addServer(
  ServerRepository repo, {
  String displayName = 'Test Server',
  String serverUrl = _kServerUrl,
  String bgeServerId = _kBgeServerId,
  ServerIdentity? identity,
}) => repo.addServer(
  displayName: displayName,
  serverUrl: serverUrl,
  bgeServerId: bgeServerId,
  identity: identity ?? _makeIdentity(serverId: bgeServerId),
);

/// Persists a server row whose `cachedIdentityJson` is [rawIdentityJson]
/// — a hand-built blob rather than one produced by
/// [ServerIdentity.toJson]. Simulates a row written by a prior app
/// version whose identity document shape has since changed (new
/// required fields, renamed wire keys); [ServerRepository.addServer]
/// can't produce such a row itself since it always encodes the current
/// shape.
///
/// Creates the row through [ServerRepository.addServer] (so every column
/// — including the internally-serialized connection state — is written
/// exactly as production would) and then overwrites only the cached
/// identity blob via a direct column update. This avoids duplicating the
/// companion's field list or the repository's private connection-state
/// serialization into the test.
Future<String> _insertRawServerRow(
  MetaDatabase database,
  ServerRepository repository, {
  required String rawIdentityJson,
  String bgeServerId = _kBgeServerId,
  String serverUrl = _kServerUrl,
}) async {
  final created = await _addServer(
    repository,
    serverUrl: serverUrl,
    bgeServerId: bgeServerId,
  );

  await (database.update(
    database.serverConfigs,
  )..where((t) => t.id.equals(created.id))).write(
    ServerConfigsCompanion(cachedIdentityJson: Value(rawIdentityJson)),
  );

  return created.id;
}

void main() {
  late MetaDatabase database;
  late ServerRepository repository;

  setUp(() {
    database = MetaDatabase.test(NativeDatabase.memory());
    repository = ServerRepositoryImpl(database);
  });

  tearDown(() async => database.close());

  group('ServerRepositoryImpl', () {
    group('addServer', () {
      test('creates server with disconnected state', () async {
        final server = await _addServer(repository);

        expect(server.id, isNotEmpty);
        expect(server.displayName, 'Test Server');
        expect(server.serverUrl, _kServerUrl);
        expect(server.connectionState, ConnectionState.disconnected);
        expect(server.bgeServerId, _kBgeServerId);
        expect(server.cachedIdentity, isNotNull);
        expect(server.lastIdentityFetchedAt, isNotNull);
        expect(server.createdAt, isNotNull);
        expect(server.updatedAt, isNotNull);
      });

      test('caches identity on creation', () async {
        final identity = _makeIdentity();
        final server = await repository.addServer(
          displayName: 'Test',
          serverUrl: _kServerUrl,
          bgeServerId: _kBgeServerId,
          identity: identity,
        );

        expect(server.cachedIdentity.serverId, _kBgeServerId);
        expect(server.cachedIdentity.issuer, _kServerUrl);
        expect(server.isIdentityStale, isFalse);
      });

      test('prevents duplicate server URL', () async {
        await _addServer(repository);

        expect(
          () => _addServer(
            repository,
            bgeServerId: 'different-uuid-1111-1111-111111111111',
          ),
          throwsA(isA<DuplicateServerException>()),
        );
      });

      test('prevents duplicate bgeServerId', () async {
        await _addServer(repository);

        expect(
          () => _addServer(repository, serverUrl: 'https://other.example.com'),
          throwsA(isA<DuplicateServerException>()),
        );
      });

      test('allows multiple servers with distinct URLs and UUIDs', () async {
        final a = await _addServer(
          repository,
          serverUrl: 'https://server-a.example.com',
          bgeServerId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        );
        final b = await _addServer(
          repository,
          serverUrl: 'https://server-b.example.com',
          bgeServerId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        );

        expect(a.id, isNot(equals(b.id)));
      });

      test('stores optional backgroundingTimeoutSeconds', () async {
        final server = await repository.addServer(
          displayName: 'Custom Timeout',
          serverUrl: _kServerUrl,
          bgeServerId: _kBgeServerId,
          identity: _makeIdentity(),
          backgroundingTimeoutSeconds: 600,
        );

        expect(server.backgroundingTimeoutSeconds, 600);
      });

      test('handles empty metadata gracefully', () async {
        final server = await _addServer(repository);
        expect(server.metadata, isEmpty);
      });
    });

    group('removeServer', () {
      test('removes disconnected server', () async {
        final server = await _addServer(repository);
        await repository.removeServer(server.id);

        expect(await repository.getServer(server.id), isNull);
      });

      test('throws ActiveServerException for active server', () async {
        final server = await _addServer(repository);
        await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.active,
        );

        expect(
          () => repository.removeServer(server.id),
          throwsA(isA<ActiveServerException>()),
        );
      });

      test('throws ServerNotFoundException for unknown id', () async {
        expect(
          () => repository.removeServer('non-existent'),
          throwsA(isA<ServerNotFoundException>()),
        );
      });
    });

    group('updateServer', () {
      test('updates displayName and metadata', () async {
        final server = await _addServer(repository);
        final updated = await repository.updateServer(
          server.copyWith(displayName: 'Renamed', metadata: {'env': 'prod'}),
        );

        expect(updated.displayName, 'Renamed');
        expect(updated.metadata['env'], 'prod');
        expect(updated.serverUrl, server.serverUrl);
      });

      test('throws ServerNotFoundException for unknown id', () async {
        final ghost = ServerConfig(
          id: 'ghost',
          bgeServerId: _kBgeServerId,
          cachedIdentity: _makeIdentity(),
          lastIdentityFetchedAt: DateTime.now().toUtc(),
          displayName: 'Ghost',
          serverUrl: 'https://ghost.example.com',
          connectionState: ConnectionState.disconnected,
        );
        expect(
          () => repository.updateServer(ghost),
          throwsA(isA<ServerNotFoundException>()),
        );
      });
    });

    group('updateConnectionState', () {
      test('transitions to active', () async {
        final server = await _addServer(repository);
        final updated = await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.active,
        );

        expect(updated.connectionState, ConnectionState.active);
        expect(updated.isActive, isTrue);
        expect(updated.isConnected, isTrue);
      });

      test('transitions through full lifecycle', () async {
        final server = await _addServer(repository);

        final active = await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.active,
        );
        expect(active.isActive, isTrue);

        final backgrounding = await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.backgrounding,
        );
        expect(backgrounding.isBackgrounding, isTrue);
        expect(backgrounding.isConnected, isTrue);

        final monitoring = await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.monitoring,
        );
        expect(monitoring.isMonitoring, isTrue);
        expect(monitoring.isConnected, isTrue);

        final disconnected = await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.disconnected,
        );
        expect(disconnected.isDisconnected, isTrue);
        expect(disconnected.isConnected, isFalse);
      });

      test('throws ServerNotFoundException for unknown id', () async {
        expect(
          () => repository.updateConnectionState(
            serverId: 'ghost',
            newState: ConnectionState.active,
          ),
          throwsA(isA<ServerNotFoundException>()),
        );
      });
    });

    group('getServer', () {
      test('returns existing server', () async {
        final created = await _addServer(repository);
        final retrieved = await repository.getServer(created.id);

        expect(retrieved?.id, created.id);
        expect(retrieved?.bgeServerId, _kBgeServerId);
      });

      test('returns null for unknown id', () async {
        expect(await repository.getServer('ghost'), isNull);
      });

      test('throws CorruptedServerIdentityException for a row whose cached '
          'identity predates required fields added in #13/#47 '
          '(well_known_schema_version, name)', () async {
        final id = await _insertRawServerRow(
          database,
          repository,
          rawIdentityJson: jsonEncode({
            // Pre-#47 shape: no well_known_schema_version, no name,
            // and the old bge_auth_base_url key rather than
            // bge_auth_base_path.
            'bge_server_id': _kBgeServerId,
            'issuer': _kServerUrl,
            'device_authorization_endpoint': '$_kServerUrl/api/auth/device',
            'bge_auth_base_url': '$_kServerUrl/api/auth',
            'bge_session_endpoint': '$_kServerUrl/api/auth/get-session',
            'bge_sign_out_endpoint': '$_kServerUrl/api/auth/sign-out',
            'bge_passkey_supported': true,
            'bge_two_factor_supported': true,
            'bge_anonymous_auth_supported': true,
            'strategies': <Map<String, dynamic>>[],
          }),
        );

        expect(
          () => repository.getServer(id),
          throwsA(isA<CorruptedServerIdentityException>()),
        );
      });

      test('CorruptedServerIdentityException identifies the offending server '
          'and carries the underlying parse error as its cause', () async {
        final id = await _insertRawServerRow(
          database,
          repository,
          rawIdentityJson: jsonEncode({'not': 'a valid identity'}),
        );

        try {
          await repository.getServer(id);
          fail('expected CorruptedServerIdentityException');
        } on CorruptedServerIdentityException catch (e) {
          expect(e.serverId, id);
          expect(e.cause, isNotNull);
        }
      });
    });

    group('getServerByBgeId', () {
      test('finds server by BGE UUID', () async {
        final server = await _addServer(repository);
        final found = await repository.getServerByBgeId(_kBgeServerId);

        expect(found?.id, server.id);
      });

      test('returns null for unknown UUID', () async {
        expect(await repository.getServerByBgeId('unknown-uuid'), isNull);
      });
    });

    group('getAllServers', () {
      test('returns all servers regardless of state', () async {
        await _addServer(
          repository,
          serverUrl: 'https://a.example.com',
          bgeServerId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        );
        await _addServer(
          repository,
          serverUrl: 'https://b.example.com',
          bgeServerId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        );

        final all = await repository.getAllServers();
        expect(all, hasLength(2));
      });
    });

    group('getConnectedServers', () {
      test('returns active, backgrounding, and monitoring servers', () async {
        final active = await _addServer(
          repository,
          serverUrl: 'https://active.example.com',
          bgeServerId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        );
        final backgrounding = await _addServer(
          repository,
          serverUrl: 'https://backgrounding.example.com',
          bgeServerId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        );
        final monitoring = await _addServer(
          repository,
          serverUrl: 'https://monitoring.example.com',
          bgeServerId: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        );
        await _addServer(
          repository,
          serverUrl: 'https://disconnected.example.com',
          bgeServerId: 'dddddddd-dddd-dddd-dddd-dddddddddddd',
        );

        await repository.updateConnectionState(
          serverId: active.id,
          newState: ConnectionState.active,
        );
        await repository.updateConnectionState(
          serverId: backgrounding.id,
          newState: ConnectionState.backgrounding,
        );
        await repository.updateConnectionState(
          serverId: monitoring.id,
          newState: ConnectionState.monitoring,
        );

        final connected = await repository.getConnectedServers();
        expect(connected, hasLength(3));
        expect(
          connected.map((s) => s.id),
          containsAll([active.id, backgrounding.id, monitoring.id]),
        );
      });
    });

    group('getConnectedCount', () {
      test('counts active + backgrounding + monitoring', () async {
        final s1 = await _addServer(
          repository,
          serverUrl: 'https://s1.example.com',
          bgeServerId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        );
        final s2 = await _addServer(
          repository,
          serverUrl: 'https://s2.example.com',
          bgeServerId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        );
        await _addServer(
          repository,
          serverUrl: 'https://s3.example.com',
          bgeServerId: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        );

        await repository.updateConnectionState(
          serverId: s1.id,
          newState: ConnectionState.active,
        );
        await repository.updateConnectionState(
          serverId: s2.id,
          newState: ConnectionState.monitoring,
        );

        expect(await repository.getConnectedCount(), 2);
      });

      test('returns 0 when all disconnected', () async {
        await _addServer(repository);
        expect(await repository.getConnectedCount(), 0);
      });
    });

    group('updateLastActive', () {
      test('updates timestamp without affecting other fields', () async {
        final server = await _addServer(repository);
        final ts = DateTime.parse('2024-06-01T12:00:00Z');

        await repository.updateLastActive(server.id, ts);

        final updated = await repository.getServer(server.id);
        expect(updated!.lastActiveAt?.toUtc(), ts);
        expect(updated.displayName, server.displayName);
        expect(updated.connectionState, server.connectionState);
      });
    });

    group('watchServers', () {
      test('emits an error through the stream for a corrupted row rather '
          'than silently dropping it or crashing uncaught', () async {
        await _insertRawServerRow(
          database,
          repository,
          rawIdentityJson: jsonEncode({'not': 'a valid identity'}),
        );

        await expectLater(
          repository.watchServers(),
          emitsError(isA<CorruptedServerIdentityException>()),
        );
      });

      test('emits current list immediately', () async {
        await _addServer(repository);

        await expectLater(
          repository.watchServers().take(1),
          emits(hasLength(1)),
        );
      });

      test('re-emits when a server is added after subscribe', () async {
        // Subscribe-then-mutate: take(2).toList() listens synchronously
        // so both the initial emission and the post-mutation emission
        // are captured.
        final futureEmissions = repository.watchServers().take(2).toList();

        await Future<void>.delayed(Duration.zero);

        await _addServer(
          repository,
          serverUrl: 'https://a.example.com',
          bgeServerId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        );

        final emissions = await futureEmissions.timeout(
          const Duration(seconds: 5),
        );
        expect(emissions, hasLength(2));
        expect(emissions[0], isEmpty);
        expect(emissions[1], hasLength(1));
      });
    });

    group('watchConnectedCount', () {
      test('emits 0 initially', () async {
        await expectLater(repository.watchConnectedCount().take(1), emits(0));
      });

      test('re-emits when connection state changes after subscribe', () async {
        final server = await _addServer(repository);
        final futureEmissions = repository
            .watchConnectedCount()
            .take(2)
            .toList();

        await Future<void>.delayed(Duration.zero);

        await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.active,
        );

        expect(
          await futureEmissions.timeout(const Duration(seconds: 5)),
          equals([0, 1]),
        );
      });
    });
  });
}
