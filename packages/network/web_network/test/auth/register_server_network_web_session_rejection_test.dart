import 'dart:async';

import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/network.dart';
import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show MergedSessionRevalidation;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:web_network/src/network/register_server_network_web.dart';

/// Where the repository reads the session: the shared identity's endpoint.
final String _sessionEndpoint = testServerIdentity().sessionEndpoint;

/// A 401 with no body, as a refused request answers.
const _unauthorized = ScriptedResponse('', status: 401);

/// #484, web leg: the origin's scope reports a 401 from any of its data
/// endpoints to the `SessionRejectionSignal` it registers, which re-reads the
/// session once for every burst. The browser holds the cookie, so every
/// session read asks the server.
void main() {
  late DependencyContainerImpl container;
  late ScriptedServer server;

  setUp(() {
    container = DependencyContainerImpl();
    registerServerNetworkWeb(
      container: container,
      identity: testServerIdentity(),
      originProvider: () => testServerUrl,
    );
    server = ScriptedServer();
    container.get<Dio>().httpClientAdapter = server;
  });

  tearDown(() async {
    await container.dispose();
  });

  group('registerServerNetworkWeb session rejection (#484)', () {
    test('registers one SessionRejectionSignal', () {
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

    test('a 401 from the auth API reads nothing', () async {
      server
        ..on('GET', '/list-accounts', (_) => _unauthorized)
        ..on('GET', _sessionEndpoint, (_) => _unauthorized);

      await container.get<Dio>().get<String>(
        '$testAuthBasePath/list-accounts',
      );
      await pumpEventQueue();

      expect(server.requestsTo('GET', _sessionEndpoint), isEmpty);
    });
  });
}
