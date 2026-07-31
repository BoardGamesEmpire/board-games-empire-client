import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import '../repositories/household_repository_impl.dart';
import '../repositories/sync_queue_repository_impl.dart';

/// [UserScopeInstaller] for the household write slice (#39, #135).
///
/// Registers the per-user [SyncQueueRepository] and [HouseholdRepository]
/// into the **user-session scope** — the per-user child of the per-server
/// scope, pushed on sign-in and popped on any transition out of the
/// authenticated state (#135). Both repositories are keyed to the current
/// user, so scoping them to the session guarantees a live query can never
/// outlive a user change: popping the scope disposes them, and the
/// household repository closes every vended `watch*` stream from its
/// dispose path.
///
/// Both depend on resources the per-server installers register — the
/// [ServerDatabase] (`StorageScopeInstaller`) and the [ClockService] +
/// [AuthRepository] (`registerServerNetwork`) — which the user-scope
/// container view resolves by falling through to the per-server scope, so
/// this installer has no ordering constraint against them (per-server
/// scopes install fully before any user session can activate).
///
/// ### User id resolution stays lazy (#128), now scope-checked (#135)
///
/// The session's user id is known at install time, but the repository still
/// receives a *provider* that reads the live [AuthRepository.currentAuthState]
/// on every household action: in the window between an authentication loss
/// and the scope pop that follows it, a lazy read fails loudly (a
/// [StateError]) instead of quietly serving data under a stale identity.
/// The provider additionally verifies the resolved id matches the id this
/// scope was built for — a *different* authenticated user under a live
/// user scope means the scope pop was missed, which must surface as a
/// wiring bug rather than as cross-user data.
///
/// The `HouseholdRemoteDataSource` the create coordinator also needs is
/// **not** registered here — it shares the per-server Dio and is registered
/// in `registerServerNetwork`, beside the resource it depends on. Wiring
/// this installer into the platform boot's user-installer list, the create
/// route, and the `HouseholdLocalizations` delegate happens together in
/// #129.
class HouseholdScopeInstaller implements UserScopeInstaller {
  const HouseholdScopeInstaller();

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
    String userId,
  ) async {
    final db = container.get<ServerDatabase>();
    final clock = container.get<ClockService>();
    final authRepository = container.get<AuthRepository>();

    final syncQueue = SyncQueueRepositoryImpl(db, clock);
    container.registerSingleton<SyncQueueRepository>(syncQueue);

    final households = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _resolveUserId(authRepository, config, userId),
      syncQueue: syncQueue,
      clock: clock,
    );
    container.registerSingleton<HouseholdRepository>(
      households,
      // Close-on-teardown (#135): scope deactivation disposes the
      // repository, which closes every vended watch stream — live
      // subscriptions stop delivering the departing user's data without
      // depending on the UI cancelling them.
      dispose: (_) => households.onDispose(),
    );
  }

  /// Reads the authenticated user id from [authRepository] at call time
  /// (#128) and verifies it is still [scopeUserId] (#135).
  ///
  /// Throws a [StateError] if invoked while unauthenticated, or if the
  /// authenticated user is no longer the one this session scope was built
  /// for. Both are unreachable in normal use — household actions are gated
  /// behind sign-in and the shell pops the scope on every authentication
  /// transition — so a throw here signals a wiring bug, not a user-facing
  /// state.
  static String _resolveUserId(
    AuthRepository authRepository,
    ServerConfig config,
    String scopeUserId,
  ) {
    final state = authRepository.currentAuthState;
    if (state is AuthStateAuthenticated) {
      final id = state.session.user.id;
      if (id != scopeUserId) {
        throw StateError(
          'A household action ran for server "${config.bgeServerId}" under '
          'a user-session scope built for "$scopeUserId", but the '
          'authenticated user is now "$id". The scope must be deactivated '
          'on every authentication transition (#135).',
        );
      }
      return id;
    }
    throw StateError(
      'A household action ran for server "${config.bgeServerId}" without an '
      'authenticated session. Household actions are only reachable behind '
      'the auth gate; the current user id is resolved lazily at call time.',
    );
  }
}
