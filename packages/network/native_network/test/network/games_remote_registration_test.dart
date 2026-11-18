import 'dart:convert';

import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:native_network/native_network.dart';
import 'package:network_interface/network_interface.dart';

import '../support/in_memory_session_tombstone_store.dart';

ServerIdentity _identity() =>
    testServerIdentity().copyWith(serverId: 'bge-uuid-1');

ServerConfig _config() => ServerConfig(
  id: 'local-1',
  displayName: 'Test BGE Server',
  serverUrl: 'https://bge.example.com',
  connectionState: ConnectionState.active,
  bgeServerId: 'bge-uuid-1',
  cachedIdentity: _identity(),
  lastIdentityFetchedAt: DateTime.utc(2026),
);

/// #42: the per-server games remote is the network installer's to register,
/// beside the other remotes and for the same reason: it shares the per-server
/// Dio, which carries the base URL and the session `/api/games` requires.
void main() {
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetwork(
      container: container,
      config: _config(),
      sessionTombstones: InMemorySessionTombstoneStore(),
    );
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetwork games remote (#42)', () {
    test('registers the interface, not the implementation type', () {
      expect(
        container.get<GamesRemoteDataSource>(),
        isA<GamesRemoteDataSourceImpl>(),
      );
      expect(container.isRegistered<GamesRemoteDataSourceImpl>(), isFalse);
    });

    test('resolves as one instance', () {
      // Requests are not sent here: this Dio's token interceptor reads secure
      // storage, which a unit test has none of. The web suite routes a
      // request through its registered Dio instead.
      expect(
        container.get<GamesRemoteDataSource>(),
        same(container.get<GamesRemoteDataSource>()),
      );
    });

    test('registers beside the other remotes, not instead of them', () {
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<GameCollectionRemoteDataSource>(), isTrue);
      expect(container.isRegistered<DataGatewayRemoteDataSource>(), isTrue);
    });
  });

  /// #473: the server scope says where the session's socket connects, and
  /// reads the handshake's token from the stored session each time it is
  /// asked, so a reconnect sends the token as it is then.
  group('registerServerNetwork realtime endpoint (#473)', () {
    /// The plugin's in-memory keychain, where this server's session is kept
    /// under its `bgeServerId`.
    late Map<String, String> keychain;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      keychain = {};
      FlutterSecureStorage.setMockInitialValues(keychain);
    });

    void storeSession(String token, {required DateTime expiresAt}) =>
        keychain['bge_session_bge-uuid-1'] = jsonEncode({
          'v': 2,
          'token': token,
          'expires_at': expiresAt.toIso8601String(),
          'persisted_at': '2026-01-01T00:00:00.000Z',
          'user': null,
        });

    test('the native server scope registers an endpoint at the server URL', () {
      final endpoint = container.get<RealtimeEndpoint>();

      expect(endpoint.server, Uri.parse('https://bge.example.com'));
      expect(endpoint.token, isNotNull);
    });

    test("its token is the stored session's, read on every call", () async {
      final token = container.get<RealtimeEndpoint>().token!;

      storeSession('tok-1', expiresAt: DateTime.utc(2099));
      expect(await token(), 'tok-1');

      storeSession('tok-2', expiresAt: DateTime.utc(2099));
      expect(await token(), 'tok-2');
    });

    test('an expired stored session gives no token', () async {
      storeSession('tok-1', expiresAt: DateTime.utc(2020));

      expect(await container.get<RealtimeEndpoint>().token!(), isNull);
    });

    test('no stored session gives no token', () async {
      expect(await container.get<RealtimeEndpoint>().token!(), isNull);
    });
  });
}
