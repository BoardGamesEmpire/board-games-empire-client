import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import '../repositories/household_repository_impl.dart';
import '../repositories/sync_queue_repository_impl.dart';

/// [ServerScopeInstaller] for the household write slice (#39).
///
/// Registers the per-server [SyncQueueRepository] and [HouseholdRepository]
/// into the scope. Both depend on resources other installers register — the
/// [ServerDatabase] (`StorageScopeInstaller`) and the [ClockService] +
/// [AuthRepository] (`registerServerNetwork`) — so this installer must run
/// **after** those: it must be placed **last** in the per-server installer
/// list, where every dependency it resolves from the container is already
/// present.
///
/// ### User id is resolved lazily (#128)
///
/// Per-server scopes activate during `ServerOrchestrator.initialize()` —
/// **before** sign-in. The current user id is therefore unknown at
/// activation and must not be read here. Instead the installer hands
/// [HouseholdRepositoryImpl] a *provider* ([_resolveUserId]) that reads the
/// live [AuthRepository.currentAuthState] each time a household action runs.
/// All household actions sit behind the auth gate, so by the time the
/// provider is invoked a session exists; if it is ever invoked without one
/// that is a programmer error and it throws a [StateError] (rather than
/// silently keying off an empty id).
///
/// This replaces the previous eager `getCachedSession()` read that assumed
/// activation only happened for a signed-in user — false, since activation
/// runs at boot — and aborted bootstrap when it didn't (#128).
///
/// The `HouseholdRemoteDataSource` the create coordinator also needs is
/// **not** registered here — it shares the per-server Dio and is registered
/// in `registerServerNetwork`, beside the resource it depends on. Wiring
/// this installer into the platform boot list, the create route, and the
/// `HouseholdLocalizations` delegate happens together in #129.
class HouseholdScopeInstaller implements ServerScopeInstaller {
  const HouseholdScopeInstaller();

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    final db = container.get<ServerDatabase>();
    final clock = container.get<ClockService>();
    final authRepository = container.get<AuthRepository>();

    final syncQueue = SyncQueueRepositoryImpl(db, clock);
    container.registerSingleton<SyncQueueRepository>(syncQueue);

    container.registerSingleton<HouseholdRepository>(
      HouseholdRepositoryImpl(
        db: db,
        currentUserId: () => _resolveUserId(authRepository, config),
        syncQueue: syncQueue,
        clock: clock,
      ),
    );
  }

  /// Reads the authenticated user id from [authRepository] at call time.
  ///
  /// Throws a [StateError] if invoked while unauthenticated — unreachable in
  /// normal use (household actions are gated behind sign-in), so a throw
  /// here signals a wiring bug, not a user-facing state.
  static String _resolveUserId(
    AuthRepository authRepository,
    ServerConfig config,
  ) {
    final state = authRepository.currentAuthState;
    if (state is AuthStateAuthenticated) {
      return state.session.user.id;
    }
    throw StateError(
      'A household action ran for server "${config.bgeServerId}" without an '
      'authenticated session. Household actions are only reachable behind '
      'the auth gate; the current user id is resolved lazily at call time.',
    );
  }
}
