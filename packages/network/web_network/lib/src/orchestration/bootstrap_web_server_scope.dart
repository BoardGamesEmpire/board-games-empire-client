import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:dio_network/dio_network.dart' show WellKnownClientImpl;
import 'package:interfaces/orchestration.dart';
import 'package:network_interface/network_interface.dart' show WellKnownClient;

import '../network/register_server_network_web.dart';
import '../network/web_dio_factory.dart';
import 'web_active_server_scope.dart';

/// Fetches the serving origin's identity and assembles the web server scope
/// (#96).
///
/// Web has no orchestrator, no MetaDB, and no persisted `ServerConfig`: the
/// browser can only talk to the origin in the address bar. This helper is the
/// web composition root's single entry point —
///
/// 1. resolves the origin via [originProvider] (the browser address bar in
///    production; injected in tests because `Uri.base` has no origin on the
///    VM);
/// 2. fetches `/.well-known/bge-identity` from that origin through the
///    platform-neutral [WellKnownClient] seam, reusing [WellKnownClientImpl]
///    (the document is unauthenticated and same-origin, so no cookie or token
///    is attached);
/// 3. builds an isolated per-server [DependencyContainer] and populates it via
///    [registerServerNetworkWeb] (shared `Dio` + `AuthRepository`, no token
///    storage — the browser owns the session cookie);
/// 4. returns a [WebActiveServerScope] holding the single origin
///    [ActiveServer], with [ActiveServer.serverId] and
///    [ActiveServer.displayName] sourced from the fetched identity
///    (`serverId` is the server-vended UUID; native instead uses the
///    client-local `ServerConfig.id` — both are opaque keying values).
///
/// The fetch runs before the container is created, so a failure leaks nothing.
/// Well-known failures (`WellKnownException` subtypes) propagate unchanged: the
/// web bootstrap (slice 2) lets them surface as the shared retryable
/// bootstrap-failure state rather than a "needs server" state — web always has
/// exactly one server by construction.
///
/// [wellKnownClient] and [originProvider] are injection seams for tests; both
/// default to production behavior.
Future<ActiveServerScope> bootstrapWebServerScope({
  WellKnownClient? wellKnownClient,
  String Function() originProvider = WebDioFactory.currentOrigin,
}) async {
  final origin = originProvider();

  // runs only from WebPlatformBootstrap.initialize(), a browser-only path.
  // On web, Dio uses the browser (Fetch/XHR) adapter, which owns no HttpClient
  // or socket pool — Dio.close() is effectively a no-op.
  final client = wellKnownClient ?? WellKnownClientImpl();

  final identity = await client.fetchIdentity(origin);

  final container = DependencyContainerImpl();
  registerServerNetworkWeb(
    container: container,
    identity: identity,
    originProvider: originProvider,
  );

  return WebActiveServerScope(
    ActiveServer(
      serverId: identity.serverId,
      displayName: identity.name,
      identity: identity,
      container: container,
    ),
  );
}
