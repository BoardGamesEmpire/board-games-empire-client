import 'package:app_shell/app_shell.dart';
import 'package:di/di.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:url_strategy/url_strategy.dart';

import 'web_root_module.dart';

/// Installs path-based URLs (no `#` fragments) so the reserved deep-link
/// paths (#10) are real browser URLs. Call first in the browser app's
/// `main()`, before `runBgeApp`.
void configureWebUrlStrategy() => setPathUrlStrategy();

/// Web [PlatformBootstrap].
///
/// The browser can only talk to the origin in the address bar: a server is
/// present by construction, there is no MetaDB, no server switching, and no
/// orchestration (confirmed #31 design). Auth is cookie-owned via
/// `web_network`; #37 wires it, fetching the origin's [ServerIdentity]
/// from its well-known document. A local data layer for web (drift/wasm
/// via `web_storage`) is designed separately in #63.
class WebPlatformBootstrap implements PlatformBootstrap {
  const WebPlatformBootstrap({
    Future<void> Function(DependencyContainer container)? rootModule,
  }) : _rootModule = rootModule;

  /// Injectable root-module seam (#69); null → [registerWebRootModule].
  /// Nullable field rather than a defaulted one so the constructor stays
  /// const for production callers.
  final Future<void> Function(DependencyContainer container)? _rootModule;

  /// Builds the web root container (#72): a fresh, isolated
  /// [DependencyContainerImpl] populated by the injected root module
  /// (production default: [registerWebRootModule] — [BuildInfo] from
  /// `version.json` plus the in-memory [FeedbackSink] stand-in; #35,
  /// #69).
  ///
  /// Fresh per call, no shared global GetIt state — see the contract on
  /// [PlatformBootstrap.createRootContainer], including the no-throw
  /// requirement the default module honors per-registration.
  ///
  /// **Dispose-partial guard** (deferred from #74's review, landed with
  /// #69): a module that throws mid-population — a contract violation —
  /// would otherwise leak whatever it registered before the throw, since
  /// `runBgeApp` discards the container for its empty fallback. The
  /// partial container is disposed here first, then the violation
  /// propagates unchanged.
  @override
  Future<DependencyContainer> createRootContainer() async {
    final container = DependencyContainerImpl();
    try {
      await (_rootModule ?? registerWebRootModule)(container);
    } on Object {
      try {
        await container.dispose();
      } on Object {
        // Intentionally ignored: a failure while disposing the partial
        // container must not mask the module's original error — that is
        // the one runBgeApp breadcrumbs and the user must see, so only
        // it is rethrown below. (Native additionally logs this secondary
        // failure at warn via its bootstrap logger; web's bootstrap
        // keeps no logger, so it is simply dropped.)
      }
      rethrow;
    }
    return container;
  }

  /// Web has no out-of-band deep-link channel (#10 decision): the browser
  /// can only navigate within its origin, the address-bar URL *is* the
  /// link, and the path URL strategy installed by
  /// [configureWebUrlStrategy] already hands it to `go_router` directly.
  /// The `/server/:serverId/...` segment in web URLs is carried for
  /// scheme parity with native but neither validated nor used for
  /// switching — single-origin means there is only one place to connect.
  @override
  DeepLinkSource? createDeepLinkSource() => null;

  @override
  Future<BootstrapResult> initialize() async =>
      const BootstrapResult(hasServer: true);

  @override
  bool get supportsReset => false;

  @override
  Future<void> reset() async {
    throw UnsupportedError(
      'reset() is not supported on web: there is no device-local meta '
      'database to delete.',
    );
  }

  @override
  Future<HydratedStorageDirectory> hydratedStorageDirectory() async =>
      HydratedStorageDirectory.web;
}
