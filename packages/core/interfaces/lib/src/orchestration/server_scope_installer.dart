import 'package:models/domain.dart';

import 'dependency_container.dart';

/// Installs one slice of a server's per-scope services into its
/// [DependencyContainer] during `ServerContext.activate()`.
///
/// This is the seam that keeps the `di` package free of concrete storage and
/// network dependencies (di must not depend on `dio_network` or
/// `drift_storage`): each implementation lives beside the concretes it wires
/// (`NetworkScopeInstaller` in `dio_network`, `StorageScopeInstaller` in
/// `drift_storage`), and the platform app composes the list it hands to
/// `ServerContextImpl`. The context only knows "run these, in order."
///
/// ## Contract
///
/// - [install] is called during activation from `initializing` or
///   `monitoring` — i.e. on a container with no per-scope registrations. It
///   is *not* called on `backgrounding → active` re-activation, where
///   resources were retained.
/// - Teardown is expressed at registration time via the container's
///   `dispose:` callbacks, never through a matching "uninstall" — suspend
///   and dispose tear the whole scope down by disposing the container.
/// - Implementations should acquire real resources (open the database,
///   build the HTTP client) inside [install] so activation failures surface
///   in `activate()` where the caller can handle them, rather than at an
///   arbitrary first use.
/// - Throwing from [install] aborts activation: the context resets the
///   scope and rolls back to its prior state. Installers therefore don't
///   need to clean up their own partial registrations.
abstract interface class ServerScopeInstaller {
  /// Wires this installer's services for [config] into [container].
  Future<void> install(DependencyContainer container, ServerConfig config);
}
