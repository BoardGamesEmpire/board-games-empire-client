import 'package:di/di.dart'
    show ContainerUserSessionScope, DependencyContainerImpl, UserScopeHost;
import 'package:dio_network/dio_network.dart' show WellKnownClientImpl;
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart' show ScopedServer, ServerIdentity;
import 'package:network_interface/network_interface.dart' show WellKnownClient;

import '../network/register_server_network_web.dart';
import '../network/web_dio_factory.dart';
import 'web_active_server_scope.dart';
import 'web_server_scope_container.dart';

/// Installs additional per-server resources into the web server scope once
/// the network stack is registered (#288).
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
/// 5. registers the per-user [UserSessionScope] over [userInstallers], when
///    there are any (#137);
/// 6. returns a [WebActiveServerScope] holding the single origin
///    [ActiveServer], with [ActiveServer.serverId] and
///    [ActiveServer.displayName] sourced from the fetched identity
///    (`serverId` is the server-vended UUID; native instead uses the
///    client-local `ServerConfig.id` — both are opaque keying values, and
///    the divergence is #334).
///
/// The container handed out is a [WebServerScopeContainer], not the raw
/// origin container: resolution checks the open user-session scope before
/// the origin scope, which is what makes per-user services reachable from
/// the shell at all (#137).
///
/// The fetch runs before the container is created, so a failure leaks nothing.
/// Well-known failures (`WellKnownException` subtypes) propagate unchanged: the
/// web bootstrap lets them surface as the shared retryable
/// bootstrap-failure state rather than a "needs server" state — web always has
/// exactly one server by construction.
///
/// A throw anywhere in the assembly propagates, and the partially populated
/// container is disposed first: the caller discards the scope on a failed
/// bootstrap, so whatever had already been put in it (a `Dio`, a clock, a
/// database) would otherwise leak. Same guard, and the same reasoning, as
/// `WebPlatformBootstrap.createRootContainer`.
///
/// [wellKnownClient] and [originProvider] are injection seams for tests; both
/// default to production behavior. [installStorage] and [userInstallers] are
/// **composition** seams, not test seams — production supplies both from
/// `web_platform`, which is the one package that depends on the network
/// stack and the data layer alike. Omitting them yields the storage-less,
/// session-scope-less scope web ran with before #288 and #137.
Future<ActiveServerScope> bootstrapWebServerScope({
  WellKnownClient? wellKnownClient,
  String Function() originProvider = WebDioFactory.currentOrigin,
  WebServerScopeInstall? installStorage,
  List<UserScopeInstaller> userInstallers = const [],
}) async {
  final origin = originProvider();

  // runs only from WebPlatformBootstrap.initialize(), a browser-only path.
  // On web, Dio uses the browser (Fetch/XHR) adapter, which owns no HttpClient
  // or socket pool — Dio.close() is effectively a no-op.
  final client = wellKnownClient ?? WellKnownClientImpl();

  final identity = await client.fetchIdentity(origin);

  // The origin scope, and the per-user child scope that hangs off it. One
  // host, shared by the container facade (which resolves through it) and the
  // `UserSessionScope` (which drives it) — two hosts over one parent would be
  // two scopes each believing it is the session.
  final originScope = DependencyContainerImpl();
  final label = 'WebServerScope(${identity.serverId})';
  final host = UserScopeHost(parent: () => originScope, label: label);

  // Built before the container so the container can route its user-scope
  // teardown through this holder's serialization chain rather than closing
  // the host behind its back. Null when this composition has no per-user
  // services — see the registration below.
  final session = userInstallers.isEmpty
      ? null
      : ContainerUserSessionScope(
          host: host,
          installers: userInstallers,
          server: ScopedServer.fromIdentity(identity),
          label: label,
        );

  final container = WebServerScopeContainer(
    base: originScope,
    host: host,
    closeSession: session?.dispose,
  );

  try {
    registerServerNetworkWeb(
      container: container,
      identity: identity,
      originProvider: originProvider,
    );

    if (installStorage != null) await installStorage(container, identity);

    // #137: the per-user tier. Registered in the *server* scope, like
    // native's, so the shell's auth listener resolves it from
    // `ActiveServer.container` the same way on both platforms.
    //
    // Only when this composition actually has per-user services to install.
    // An empty list means there are none — the storage-less scope is the
    // real case — and the shell reads an absent `UserSessionScope` as
    // exactly that, skipping the scope step. Registering one anyway would
    // build and tear down an empty child scope on every sign-in.
    if (session != null) {
      container.registerSingleton<UserSessionScope>(
        session,
        // The holder's terminal state: disposing the server scope ends any
        // live session and closes the holder for good, so a late activation
        // cannot build a child scope nothing will ever dispose. Idempotent,
        // so it costs nothing when the container's own dispose already
        // routed through it.
        dispose: (_) => session.dispose(),
      );
    }
  } on Object {
    try {
      await container.dispose();
    } on Object {
      // Intentionally ignored: a failure while disposing the partial
      // container must not mask the failure that got us here, which is the
      // one the bootstrap surfaces and the user has to act on.
    }
    rethrow;
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
