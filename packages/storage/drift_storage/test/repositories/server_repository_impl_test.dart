import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/repositories/server_repository_impl.dart';
import 'package:interfaces/interfaces.dart';
import 'package:models/domain.dart';

void main() {
  late MetaDatabase database;
  late ServerRepository repository;

  setUp(() {
    database = MetaDatabase.test(NativeDatabase.memory());
    repository = ServerRepositoryImpl(database);
  });

  tearDown(() async {
    await database.close();
  });

  group('ServerRepositoryImpl', () {
    group('addServer', () {
      test('creates server with disconnected state', () async {
        final server = await repository.addServer(
          displayName: 'Test Server',
          serverUrl: 'https://test.example.com',
          metadata: {'region': 'us-east'},
        );

        expect(server.id, isNotEmpty);
        expect(server.displayName, 'Test Server');
        expect(server.serverUrl, 'https://test.example.com');
        expect(server.connectionState, ConnectionState.disconnected);
        expect(server.metadata['region'], 'us-east');
        expect(server.createdAt, isNotNull);
        expect(server.updatedAt, isNotNull);
      });

      test('prevents duplicate server URLs', () async {
        await repository.addServer(
          displayName: 'First',
          serverUrl: 'https://duplicate.example.com',
        );

        expect(
          () => repository.addServer(
            displayName: 'Second',
            serverUrl: 'https://duplicate.example.com',
          ),
          throwsA(isA<DuplicateServerException>()),
        );
      });

      test('allows different URLs for different servers', () async {
        final first = await repository.addServer(
          displayName: 'First',
          serverUrl: 'https://first.example.com',
        );

        final second = await repository.addServer(
          displayName: 'Second',
          serverUrl: 'https://second.example.com',
        );

        expect(first.id, isNot(equals(second.id)));
        expect(first.serverUrl, isNot(equals(second.serverUrl)));
      });

      test('handles empty metadata gracefully', () async {
        final server = await repository.addServer(
          displayName: 'Minimal',
          serverUrl: 'https://minimal.example.com',
        );

        expect(server.metadata, isEmpty);
      });
    });

    group('removeServer', () {
      test('removes disconnected server successfully', () async {
        final server = await repository.addServer(
          displayName: 'To Remove',
          serverUrl: 'https://remove.example.com',
        );

        await repository.removeServer(server.id);

        final retrieved = await repository.getServer(server.id);
        expect(retrieved, isNull);
      });

      test('prevents removing active server', () async {
        final server = await repository.addServer(
          displayName: 'Active',
          serverUrl: 'https://active.example.com',
        );

        await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.active,
        );

        expect(
          () => repository.removeServer(server.id),
          throwsA(isA<ActiveServerException>()),
        );
      });

      test('throws when removing non-existent server', () async {
        expect(
          () => repository.removeServer('non_existent_id'),
          throwsA(isA<ServerNotFoundException>()),
        );
      });
    });

    group('updateServer', () {
      test('updates display name and metadata', () async {
        final original = await repository.addServer(
          displayName: 'Original',
          serverUrl: 'https://original.example.com',
          metadata: {'key': 'value'},
        );

        final updated = await repository.updateServer(
          original.copyWith(
            displayName: 'Updated',
            metadata: {'key': 'new_value', 'extra': 'data'},
          ),
        );

        expect(updated.displayName, 'Updated');
        expect(updated.metadata['key'], 'new_value');
        expect(updated.metadata['extra'], 'data');
        expect(updated.serverUrl, original.serverUrl);
        expect(updated.id, original.id);
      });

      test('throws when updating non-existent server', () async {
        final config = ServerConfig(
          id: 'non_existent',
          displayName: 'Ghost',
          serverUrl: 'https://ghost.example.com',
          connectionState: ConnectionState.disconnected,
        );

        expect(
          () => repository.updateServer(config),
          throwsA(isA<ServerNotFoundException>()),
        );
      });
    });

    group('updateConnectionState', () {
      test('transitions from disconnected to monitoring', () async {
        final server = await repository.addServer(
          displayName: 'Test',
          serverUrl: 'https://test.example.com',
        );

        final updated = await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.monitoring,
        );

        expect(updated.connectionState, ConnectionState.monitoring);
      });

      test('transitions from monitoring to active', () async {
        final server = await repository.addServer(
          displayName: 'Test',
          serverUrl: 'https://test.example.com',
        );

        await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.monitoring,
        );

        final updated = await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.active,
        );

        expect(updated.connectionState, ConnectionState.active);
      });

      test('enforces monitoring capacity limit', () async {
        // Create and connect 5 servers
        for (int i = 0; i < 5; i++) {
          final server = await repository.addServer(
            displayName: 'Server $i',
            serverUrl: 'https://server$i.example.com',
          );
          await repository.updateConnectionState(
            serverId: server.id,
            newState: ConnectionState.monitoring,
          );
        }

        // Attempt to connect 6th server
        final sixth = await repository.addServer(
          displayName: 'Server 6',
          serverUrl: 'https://server6.example.com',
        );

        expect(
          () => repository.updateConnectionState(
            serverId: sixth.id,
            newState: ConnectionState.monitoring,
          ),
          throwsA(
            isA<ServerCapacityExceededException>()
                .having((e) => e.currentMonitored, 'currentMonitored', 5)
                .having((e) => e.maxCapacity, 'maxCapacity', 5),
          ),
        );
      });

      test('allows disconnecting monitored server freeing capacity', () async {
        // Fill capacity
        final servers = <ServerConfig>[];
        for (int i = 0; i < 5; i++) {
          final server = await repository.addServer(
            displayName: 'Server $i',
            serverUrl: 'https://server$i.example.com',
          );
          await repository.updateConnectionState(
            serverId: server.id,
            newState: ConnectionState.monitoring,
          );
          servers.add(server);
        }

        // Disconnect one
        await repository.updateConnectionState(
          serverId: servers[0].id,
          newState: ConnectionState.disconnected,
        );

        // Now can connect another
        final newServer = await repository.addServer(
          displayName: 'New Server',
          serverUrl: 'https://newserver.example.com',
        );

        await expectLater(
          repository.updateConnectionState(
            serverId: newServer.id,
            newState: ConnectionState.monitoring,
          ),
          completes,
        );
      });

      test('throws when updating non-existent server', () async {
        expect(
          () => repository.updateConnectionState(
            serverId: 'non_existent',
            newState: ConnectionState.active,
          ),
          throwsA(isA<ServerNotFoundException>()),
        );
      });
    });

    group('getServer', () {
      test('retrieves existing server by id', () async {
        final created = await repository.addServer(
          displayName: 'Test',
          serverUrl: 'https://test.example.com',
        );

        final retrieved = await repository.getServer(created.id);

        expect(retrieved, isNotNull);
        expect(retrieved!.id, created.id);
        expect(retrieved.displayName, created.displayName);
      });

      test('returns null for non-existent server', () async {
        final result = await repository.getServer('non_existent');
        expect(result, isNull);
      });
    });

    group('getAllServers', () {
      test('returns all servers regardless of state', () async {
        await repository.addServer(
          displayName: 'Active',
          serverUrl: 'https://active.example.com',
        );
        await repository.addServer(
          displayName: 'Monitoring',
          serverUrl: 'https://monitoring.example.com',
        );
        await repository.addServer(
          displayName: 'Disconnected',
          serverUrl: 'https://disconnected.example.com',
        );

        final all = await repository.getAllServers();
        expect(all, hasLength(3));
      });

      test('returns empty list when no servers configured', () async {
        final all = await repository.getAllServers();
        expect(all, isEmpty);
      });
    });

    group('getMonitoredServers', () {
      test('returns only active and monitoring servers', () async {
        final active = await repository.addServer(
          displayName: 'Active',
          serverUrl: 'https://active.example.com',
        );
        final monitoring = await repository.addServer(
          displayName: 'Monitoring',
          serverUrl: 'https://monitoring.example.com',
        );
        await repository.addServer(
          displayName: 'Disconnected',
          serverUrl: 'https://disconnected.example.com',
        );

        await repository.updateConnectionState(
          serverId: active.id,
          newState: ConnectionState.active,
        );
        await repository.updateConnectionState(
          serverId: monitoring.id,
          newState: ConnectionState.monitoring,
        );

        final monitored = await repository.getMonitoredServers();
        expect(monitored, hasLength(2));
        expect(
          monitored.map((s) => s.id),
          containsAll([active.id, monitoring.id]),
        );
      });
    });

    group('getDisconnectedServers', () {
      test('returns only disconnected servers', () async {
        final disconnected = await repository.addServer(
          displayName: 'Disconnected',
          serverUrl: 'https://disconnected.example.com',
        );
        final active = await repository.addServer(
          displayName: 'Active',
          serverUrl: 'https://active.example.com',
        );

        await repository.updateConnectionState(
          serverId: active.id,
          newState: ConnectionState.active,
        );

        final disconnectedList = await repository.getDisconnectedServers();
        expect(disconnectedList, hasLength(1));
        expect(disconnectedList[0].id, disconnected.id);
      });
    });

    group('getMonitoredCount', () {
      test('counts active and monitoring servers', () async {
        final server1 = await repository.addServer(
          displayName: 'Server 1',
          serverUrl: 'https://server1.example.com',
        );
        final server2 = await repository.addServer(
          displayName: 'Server 2',
          serverUrl: 'https://server2.example.com',
        );
        await repository.addServer(
          displayName: 'Server 3',
          serverUrl: 'https://server3.example.com',
        );

        await repository.updateConnectionState(
          serverId: server1.id,
          newState: ConnectionState.active,
        );
        await repository.updateConnectionState(
          serverId: server2.id,
          newState: ConnectionState.monitoring,
        );

        final count = await repository.getMonitoredCount();
        expect(count, 2);
      });

      test('returns zero when no servers monitored', () async {
        await repository.addServer(
          displayName: 'Disconnected',
          serverUrl: 'https://disconnected.example.com',
        );

        final count = await repository.getMonitoredCount();
        expect(count, 0);
      });
    });

    group('updateLastActive', () {
      test('updates timestamp without affecting other fields', () async {
        final server = await repository.addServer(
          displayName: 'Test',
          serverUrl: 'https://test.example.com',
        );

        final timestamp = DateTime.parse('2024-01-15T10:30:00Z').toUtc();
        await repository.updateLastActive(server.id, timestamp);

        final updated = await repository.getServer(server.id);
        expect(updated!.lastActiveAt!.toUtc(), timestamp.toUtc());
        expect(updated.displayName, server.displayName);
        expect(updated.connectionState, server.connectionState);
      });
    });

    group('watchServers', () {
      test('emits current servers immediately', () async {
        await repository.addServer(
          displayName: 'Test',
          serverUrl: 'https://test.example.com',
        );

        final stream = repository.watchServers();
        final first = await stream.first;
        expect(first, hasLength(1));
      });

      test('emits updates when servers added', () async {
        final stream = repository.watchServers();
        final events = <List<ServerConfig>>[];

        final subscription = stream.listen(events.add);

        await Future.delayed(Duration(milliseconds: 50));

        await repository.addServer(
          displayName: 'First',
          serverUrl: 'https://first.example.com',
        );

        await Future.delayed(Duration(milliseconds: 50));

        await repository.addServer(
          displayName: 'Second',
          serverUrl: 'https://second.example.com',
        );

        await Future.delayed(Duration(milliseconds: 50));
        await subscription.cancel();

        expect(events.length, greaterThanOrEqualTo(2));
        expect(events.last, hasLength(2));
      });
    });

    group('watchMonitoredCount', () {
      test('emits initial count', () async {
        final server = await repository.addServer(
          displayName: 'Test',
          serverUrl: 'https://test.example.com',
        );
        await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.monitoring,
        );

        final stream = repository.watchMonitoredCount();
        final first = await stream.first;
        expect(first, 1);
      });

      test('emits updates when connection state changes', () async {
        final server = await repository.addServer(
          displayName: 'Test',
          serverUrl: 'https://test.example.com',
        );

        final stream = repository.watchMonitoredCount();
        final events = <int>[];

        final subscription = stream.listen(events.add);
        await Future.delayed(Duration(milliseconds: 50));

        await repository.updateConnectionState(
          serverId: server.id,
          newState: ConnectionState.monitoring,
        );

        await Future.delayed(Duration(milliseconds: 50));
        await subscription.cancel();

        expect(events, contains(0));
        expect(events, contains(1));
      });
    });
  });
}
