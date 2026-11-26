import 'dart:async';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:native_network/native_network.dart';

import '../support/in_memory_session_tombstone_store.dart';

/// Where the repository reads the session: the shared identity's endpoint.
final String _sessionEndpoint = testServerIdentity().sessionEndpoint;

ServerConfig _config({String serverUrl = testServerUrl}) => ServerConfig(
  id: 'local-1',
  displayName: 'Test BGE Server',
  serverUrl: serverUrl,
  connectionState: ConnectionState.active,
  bgeServerId: 'bge-uuid-1',
  cachedIdentity: testServerIdentity().copyWith(serverId: 'bge-uuid-1'),
  lastIdentityFetchedAt: DateTime.utc(2026),
);

/// A 401 with no body, as a refused request answers.
const _unauthorized = ScriptedResponse('', status: 401);

/// #484: the server scope reports a 401 from any of its data endpoints to the
/// `SessionRejectionSignal` it registers, which re-reads the session once for
/// every burst. Everything between the request and the session read is real:
/// the per-server Dio and its interceptors, the repository and the token
/// storage. Only the keychain and the socket are replaced.
void main() {
  late DependencyContainerImpl container;
  late ScriptedServer server;

  /// Registers the server scope for [config], on [server], with a session
  /// stored, since a session read with nothing stored never asks the server.
  Future<void> serve({ServerConfig? config}) async {
    registerServerNetwork(
      container: container,
      config: config ?? _config(),
      sessionTombstones: InMemorySessionTombstoneStore(),
    );
    container.get<Dio>().httpClientAdapter = server;
    await container.get<TokenStorageService>().store(
      token: 'tok-A',
      expiresAt: null,
      persistedAt: DateTime.utc(2026),
    );
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    container = DependencyContainerImpl();
    server = ScriptedServer();
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetwork session rejection (#484)', () {
    test('registers one SessionRejectionSignal', () async {
      await serve();

      expect(
        container.get<SessionRejectionSignal>(),
        isA<MergedSessionRevalidation>(),
      );
      expect(
        container.get<SessionRejectionSignal>(),
        same(container.get<SessionRejectionSignal>()),
      );
    });

    test('a 401 from a data endpoint re-reads the session once', () async {
      await serve();
      final states = <AuthState>[];
      final subscription = container
          .get<AuthRepository>()
          .watchAuthState()
          .listen(states.add);
      addTearDown(subscription.cancel);
      // Held until every 401 has landed, so they all arrive while the first
      // one's session read is still out.
      final sessionRead = Completer<ScriptedResponse>();
      server
        ..on('GET', '/api/x', (_) => _unauthorized)
        ..hold('GET', _sessionEndpoint, sessionRead.future);

      final dio = container.get<Dio>();
      await Future.wait([
        for (var i = 0; i < 3; i++) dio.get<String>('/api/x'),
      ]);
      sessionRead.complete(_unauthorized);
      await pumpEventQueue();

      expect(server.requestsTo('GET', _sessionEndpoint), hasLength(1));
      expect(states.last, isA<AuthStateUnauthenticated>());
    });

    test('a 401 from the auth API reads nothing, on a server under a path '
        'prefix', () async {
      // The auth base is the server's address with the auth path appended,
      // as the repository's requests reach it, not the auth path resolved
      // against the address, which drops the prefix.
      await serve(config: _config(serverUrl: '$testServerUrl/bge'));
      server
        ..on('GET', '/list-accounts', (_) => _unauthorized)
        ..on('GET', '/api/x', (_) => _unauthorized)
        ..on('GET', _sessionEndpoint, (_) => _unauthorized);
      final dio = container.get<Dio>();

      await dio.get<String>('$testAuthBasePath/list-accounts');
      await pumpEventQueue();

      expect(server.requestsTo('GET', _sessionEndpoint), isEmpty);

      await dio.get<String>('/api/x');
      await pumpEventQueue();

      expect(server.requestsTo('GET', _sessionEndpoint), hasLength(1));
    });
  });
}
