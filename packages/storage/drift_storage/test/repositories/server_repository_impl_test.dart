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
  deviceAuthorizationEndpoint: '$issuer/api/auth/device',
  authBaseUrl: '$issuer/api/auth',
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
      test('emits current list immediately', () async {
        await _addServer(repository);

        await expectLater(
          repository.watchServers().take(1),
          emits(hasLength(1)),
        );
      });

      test('emits on add', () async {
        final stream = repository.watchServers();

        await _addServer(
          repository,
          serverUrl: 'https://a.example.com',
          bgeServerId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        );

        await expectLater(
          stream.take(2),
          emitsInOrder([isEmpty, hasLength(1)]),
        );
      });
    });

    group('watchConnectedCount', () {
      test('emits 0 initially', () async {
        await expectLater(repository.watchConnectedCount().take(1), emits(0));
      });

      test('increments on connection state change', () async {
        final server = await _addServer(repository);
        final stream = repository.watchConnectedCount();

        await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.active,
        );

        await expectLater(stream.take(2), emitsInOrder([0, 1]));
      });
    });
  });
}
