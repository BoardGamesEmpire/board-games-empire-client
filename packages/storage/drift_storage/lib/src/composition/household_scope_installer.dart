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
/// **App wiring is deliberately deferred to #129** (home menu / navigation
/// shell), which is blocked by **#128**. The platform bootstrap
/// (`native_platform_bootstrap.dart`) therefore still lists only
/// `StorageScopeInstaller` and `NetworkScopeInstaller`, and nothing yet
/// constructs `CreateHouseholdScreen` or registers `HouseholdLocalizations`:
/// until #129 lands, `HouseholdRepository` is registered nowhere and the
/// create slice is not reachable from the UI.
///
/// The deferral is not cosmetic. Adding this installer to the boot-time list
/// as written crashes bootstrap: per-server scopes activate during
/// `ServerOrchestrator.initialize()` — **before** sign-in — so the session
/// read below throws and aborts activation (#128). #128 makes user-scoped
/// per-server repositories registerable without a session (resolving the user
/// id lazily at call time); #129 then wires the route, the l10n delegate, and
/// this installer together behind a real menu.
///
/// `currentUserId` is resolved once here, at activation, from the cached
/// session ([AuthRepository.getCachedSession]); if none is present the install
/// throws, aborting activation per the [ServerScopeInstaller] contract rather
/// than registering a user-less repository.
///
/// **This eager resolution is the #128 defect** — it assumes scope activation
/// only happens for a signed-in user, which is false: activation runs at boot,
/// before authentication. #128 replaces it with a lazily-resolved user id
/// (reading [AuthRepository.currentAuthState] at call time), so the scope
/// registers pre-auth and the id is bound when a household action actually
/// runs. Left as-is here so the fix lands as one reviewable change in #128.
///
/// The `HouseholdRemoteDataSource` the create coordinator also needs is
/// **not** registered here — it shares the per-server Dio and is registered
/// in `registerServerNetwork`, beside the resource it depends on.
class HouseholdScopeInstaller implements ServerScopeInstaller {
  const HouseholdScopeInstaller();

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    final db = container.get<ServerDatabase>();
    final clock = container.get<ClockService>();

    final session = await container.get<AuthRepository>().getCachedSession();
    final userId = session?.user.id;
    if (userId == null) {
      throw StateError(
        'HouseholdScopeInstaller requires a signed-in session for server '
        '"${config.bgeServerId}", but none was cached. Household scope '
        'activation must follow authentication.',
      );
    }

    final syncQueue = SyncQueueRepositoryImpl(db, clock);
    container.registerSingleton<SyncQueueRepository>(syncQueue);

    container.registerSingleton<HouseholdRepository>(
      HouseholdRepositoryImpl(
        db: db,
        currentUserId: userId,
        syncQueue: syncQueue,
        clock: clock,
      ),
    );
  }
}
