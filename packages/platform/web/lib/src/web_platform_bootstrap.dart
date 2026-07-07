import 'package:app_shell/app_shell.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:url_strategy/url_strategy.dart';

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
  const WebPlatformBootstrap();

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
