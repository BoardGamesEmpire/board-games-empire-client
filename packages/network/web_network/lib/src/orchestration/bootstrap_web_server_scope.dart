import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:dio_network/dio_network.dart' show WellKnownClientImpl;
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart' show ServerIdentity;
import 'package:network_interface/network_interface.dart' show WellKnownClient;

import '../network/register_server_network_web.dart';
import '../network/web_dio_factory.dart';
import 'web_active_server_scope.dart';

/// Installs additional per-server resources into the web server scope once
/// the network stack is registered (#288 **D3**).
///
/// Exists so the web data layer can be registered without this package
/// depending on it: `web_storage` reaches `package:drift/wasm.dart`, and a
/// dependency edge from here would drag a browser-only library into the
/// network package every native target also builds. `web_platform` depends
/// on both and is where the two are composed.
///
/// Called with the same [DependencyContainer] the network stack was
/// registered into, and with the fetched [ServerIdentity] — which is web's
/// only per-server identifier, there being no persisted `ServerConfig`.
typedef WebServerScopeInstall = Future<void> Function(
  DependencyContainer container,
  ServerIdentity identity,
);

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
/// 4. runs [installStorage], if given, so the web data layer (#288) is
///    registered into that same container before anything can resolve from
///    it;
/// 5. returns a [WebActiveServerScope] holding the single origin
///    [ActiveServer], with [ActiveServer.serverId] and
///    [ActiveServer.displayName] sourced from the fetched identity
///    (`serverId` is the server-vended UUID; native instead uses the
///    client-local `ServerConfig.id` — both are opaque keying values).
///
/// The fetch runs before the container is created, so a failure leaks nothing.
/// Well-known failures (`WellKnownException` subtypes) propagate unchanged: the
/// web bootstrap lets them surface as the shared retryable
/// bootstrap-failure state rather than a "needs server" state — web always has
/// exactly one server by construction.
///
/// A throw from [installStorage] propagates, and the partially populated
/// container is disposed first: the caller discards the scope on a failed
/// bootstrap, so whatever the network registration had already put in it
/// (a `Dio`, a clock) would otherwise leak. Same guard, and the same
/// reasoning, as `WebPlatformBootstrap.createRootContainer`.
///
/// [wellKnownClient] and [originProvider] are injection seams for tests; both
/// default to production behavior. [installStorage] is a **composition**
/// seam, not a test seam — production supplies it from `web_platform`, and
/// omitting it yields the storage-less scope web ran with before #288.
Future<ActiveServerScope> bootstrapWebServerScope({
  WellKnownClient? wellKnownClient,
  String Function() originProvider = WebDioFactory.currentOrigin,
  WebServerScopeInstall? installStorage,
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

  if (installStorage != null) {
    try {
      await installStorage(container, identity);
    } on Object {
      try {
        await container.dispose();
      } on Object {
        // Intentionally ignored: a failure while disposing the partial
        // container must not mask the storage failure, which is the one
        // the bootstrap surfaces and the user has to act on.
      }
      rethrow;
    }
  }

  return WebActiveServerScope(
    ActiveServer(
      serverId: identity.serverId,
      displayName: identity.name,
      identity: identity,
      container: container,
    ),
  );
}
