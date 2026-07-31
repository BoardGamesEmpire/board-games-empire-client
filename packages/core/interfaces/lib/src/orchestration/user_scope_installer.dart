import 'package:models/domain.dart';

import 'dependency_container.dart';

/// Installs one slice of per-user services into a server's **user-session
/// scope** during `UserSessionScope.activate()` (#135).
///
/// The user-session scope is a child of the per-server scope, keyed by the
/// (server, user-id-on-that-server) pair: it is pushed when a user
/// authenticates on that server and popped on any transition out of the
/// authenticated state (explicit sign-out or a mid-session authentication
/// loss). Per-user singletons registered here — repositories whose queries
/// are keyed to the current user, their sync-queue collaborators — are
/// therefore rebuilt for every user change, so a live query can never keep
/// serving the previous user's data.
///
/// User identity is per-server: the same person signed into two servers has
/// two independent user-session scopes with distinct [userId]s. Nothing
/// registered here is shared across server scopes.
///
/// This mirrors [ServerScopeInstaller]'s seam role: implementations live
/// beside the concretes they wire (e.g. `HouseholdScopeInstaller` in
/// `drift_storage`), and the platform app composes the list it hands to
/// `ServerContextImpl` — the `di` package stays free of storage and network
/// dependencies.
///
/// ## Contract
///
/// - [install] runs against a container **view** whose registrations land in
///   the user-session scope while resolution falls through to the per-server
///   scope — so an installer freely resolves server-lifetime resources (the
///   per-server database, `ClockService`, `AuthRepository`) and registers
///   per-user services beside them.
/// - Installers run in list order; an installer may resolve services a
///   predecessor registered.
/// - Teardown is expressed at registration time via the container's
///   `dispose:` callbacks, never through a matching "uninstall" — scope
///   deactivation disposes the whole user-session scope. Services vending
///   streams must close them from their dispose path so live subscriptions
///   stop delivering the departing user's data.
/// - Throwing from [install] aborts activation: the partial user-session
///   scope is discarded (the per-server scope is untouched) and the error
///   propagates to the caller. Installers therefore don't need to clean up
///   their own partial registrations.
abstract interface class UserScopeInstaller {
  /// Wires this installer's per-user services for [userId] on the server
  /// described by [config] into [container].
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
    String userId,
  );
}
