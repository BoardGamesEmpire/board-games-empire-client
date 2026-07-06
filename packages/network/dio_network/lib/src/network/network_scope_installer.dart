import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

import 'register_server_network.dart';

/// [ServerScopeInstaller] for the mobile/desktop network slice.
///
/// Thin adapter over [registerServerNetwork], which remains the actual
/// composition root for the Dio-based stack (TokenStorageService →
/// TokenInterceptor → DioFactory → shared Dio → AuthRepository). The
/// installer form is what `ServerContextImpl` consumes without `di` ever
/// depending on this package; the platform app composes it into the
/// context's installer list alongside `StorageScopeInstaller`.
///
/// Teardown is already expressed inside [registerServerNetwork] via the
/// container's `dispose:` callbacks (the container owns and closes the
/// shared Dio; the auth repository disposes only its own resources), so
/// suspend/dispose need nothing further from this class.
///
/// The web variant (httpOnly-cookie transport, `web_network`) gets its own
/// installer; this one must never be composed into a browser build.
class NetworkScopeInstaller implements ServerScopeInstaller {
  const NetworkScopeInstaller();

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    registerServerNetwork(container: container, config: config);
  }
}
