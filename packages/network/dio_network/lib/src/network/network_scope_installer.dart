import 'package:dio_network/src/network/register_server_network.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart' show ProviderSignInBrowser;
import 'package:models/domain.dart';

/// [ServerScopeInstaller] for the mobile/desktop network slice.
///
/// Thin adapter over [registerServerNetwork], which remains the actual
/// composition root for the Dio-based stack (TokenStorageService →
/// TokenInterceptor → DioFactory → shared Dio → AuthRepository). The
/// installer form is what `ServerContextImpl` consumes without `di` ever
/// depending on this package; the platform app composes it into the
/// context's installer list alongside `StorageScopeInstaller`.
///
/// Teardown is already expressed inside [registerServerNetwork]: the shared
/// Dio's `dispose:` callback closes it, and the container closes the
/// `Disposable` auth repository, which disposes only its own resources. So
/// suspend/dispose need nothing further from this class.
///
/// The web variant (httpOnly-cookie transport, `web_network`) gets its own
/// installer; this one must never be composed into a browser build.
class NetworkScopeInstaller implements ServerScopeInstaller {
  const NetworkScopeInstaller({
    required this._sessionTombstones,
    required this.providerBrowser,
  });

  final SessionTombstoneStore _sessionTombstones;

  /// The in-app browser tab a provider sign-in runs in (#583). Required, so
  /// a platform composition cannot forget it and silently lose the feature.
  final ProviderSignInBrowser providerBrowser;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    registerServerNetwork(
      container: container,
      config: config,
      sessionTombstones: _sessionTombstones,
      providerBrowser: providerBrowser,
    );
  }
}
