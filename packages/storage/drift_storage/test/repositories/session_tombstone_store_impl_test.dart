import 'package:bge_test_support/domain.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/repositories/server_repository_impl.dart';
import 'package:drift_storage/src/repositories/session_tombstone_store_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

const _kBgeServerId = 'bge-1';
const String _kServerUrl = testServerUrl;

ServerIdentity _makeIdentity() =>
    testServerIdentity().copyWith(serverId: _kBgeServerId);

/// A time no write made now can equal, so a store that touched `updated_at`
/// can't pass by landing in the same millisecond as `addServer`.
final _pinnedUpdatedAt = DateTime.utc(2020);

void main() {
  late MetaDatabase database;
  late ServerRepositoryImpl servers;
  late SessionTombstoneStoreImpl store;
  late ServerConfig server;

  setUp(() async {
    database = MetaDatabase.test(NativeDatabase.memory());
    servers = ServerRepositoryImpl(database);
    store = SessionTombstoneStoreImpl(database);
    // The row's local `id` is a generated CUID, so it differs from the
    // `bgeServerId` the store is keyed by.
    server = await servers.addServer(
      displayName: 'Test Server',
      serverUrl: _kServerUrl,
      bgeServerId: _kBgeServerId,
      identity: _makeIdentity(),
    );
    await (database.update(database.serverConfigs)
          ..where((t) => t.id.equals(server.id)))
        .write(ServerConfigsCompanion(updatedAt: Value(_pinnedUpdatedAt)));
  });

  tearDown(() => database.close());

  test('a server starts not revoked', () async {
    expect(await store.isRevoked(_kBgeServerId), isFalse);
  });

  test('markRevoked is read back, across a new store instance', () async {
    await store.markRevoked(_kBgeServerId);

    expect(await store.isRevoked(_kBgeServerId), isTrue);
    expect(
      await SessionTombstoneStoreImpl(database).isRevoked(_kBgeServerId),
      isTrue,
    );
  });

  test('markRevoked stamps a UTC time and leaves updatedAt alone', () async {
    final before = DateTime.now().toUtc();
    await store.markRevoked(_kBgeServerId);
    final after = DateTime.now().toUtc();

    final row = await (database.select(
      database.serverConfigs,
    )..where((t) => t.bgeServerId.equals(_kBgeServerId))).getSingle();

    final revokedAt = row.sessionRevokedAt!;
    expect(revokedAt.isUtc, isTrue);
    expect(revokedAt.isBefore(before), isFalse);
    expect(revokedAt.isAfter(after), isFalse);
    expect(row.updatedAt, _pinnedUpdatedAt);
  });

  test('markRevoked on one server leaves another not revoked', () async {
    await servers.addServer(
      displayName: 'Other Server',
      serverUrl: 'https://other.example.com',
      bgeServerId: 'bge-2',
      identity: _makeIdentity(),
    );

    await store.markRevoked(_kBgeServerId);

    expect(await store.isRevoked('bge-2'), isFalse);
  });

  test('clearRevoked removes the marker', () async {
    await store.markRevoked(_kBgeServerId);

    await store.clearRevoked(_kBgeServerId);

    expect(await store.isRevoked(_kBgeServerId), isFalse);
  });

  test('clearRevoked notifies table watchers only when it removes a '
      'marker', () async {
    var notifications = 0;
    final subscription = database.tableUpdates().listen(
      (_) => notifications += 1,
    );
    addTearDown(subscription.cancel);

    await store.clearRevoked(_kBgeServerId);
    await pumpEventQueue();
    expect(notifications, 0);

    await store.markRevoked(_kBgeServerId);
    await store.clearRevoked(_kBgeServerId);
    await pumpEventQueue();
    expect(notifications, 2);
  });

  test('clearRevoked leaves updatedAt alone', () async {
    await store.markRevoked(_kBgeServerId);

    await store.clearRevoked(_kBgeServerId);

    final row = await (database.select(
      database.serverConfigs,
    )..where((t) => t.bgeServerId.equals(_kBgeServerId))).getSingle();
    expect(row.updatedAt, _pinnedUpdatedAt);
  });

  test(
    'markRevoked with no matching row throws ServerNotFoundException',
    () async {
      await expectLater(
        store.markRevoked('bge-unknown'),
        throwsA(
          isA<ServerNotFoundException>().having(
            (e) => e.serverId,
            'serverId',
            'bge-unknown',
          ),
        ),
      );
    },
  );

  test(
    'markRevoked is keyed by bgeServerId, so the local id matches nothing',
    () async {
      await expectLater(
        store.markRevoked(server.id),
        throwsA(isA<ServerNotFoundException>()),
      );

      expect(await store.isRevoked(_kBgeServerId), isFalse);
    },
  );

  test('clearRevoked with no matching row does nothing', () async {
    await store.clearRevoked('bge-unknown');

    expect(await store.isRevoked(_kBgeServerId), isFalse);
  });

  test('isRevoked with no matching row is false', () async {
    expect(await store.isRevoked('bge-unknown'), isFalse);
  });

  test('updateServer leaves the marker in place', () async {
    await store.markRevoked(_kBgeServerId);

    await servers.updateServer(server.copyWith(displayName: 'Renamed'));

    expect(await store.isRevoked(_kBgeServerId), isTrue);
  });

  test('removeServer takes the marker with the row', () async {
    await store.markRevoked(_kBgeServerId);

    await servers.removeServer(server.id);

    expect(await store.isRevoked(_kBgeServerId), isFalse);

    // A server registered again under the same id does not inherit it.
    await servers.addServer(
      displayName: 'Test Server',
      serverUrl: _kServerUrl,
      bgeServerId: _kBgeServerId,
      identity: _makeIdentity(),
    );
    expect(await store.isRevoked(_kBgeServerId), isFalse);
  });
}
