import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'session_confirming_sender.dart';
import 'sync_operation_sender_impl.dart';

/// Registers the session's [SyncOperationSender] (#121): the one delivery
/// path the inline household create and the queue drain share.
///
/// Both composition roots hold it, `buildNativeUserScopeInstallers` and
/// `buildWebUserScopeInstallers`, because the create screen sends through it
/// on both. Only native runs a drain over it so far; the web drain is #447.
///
/// It resolves the [SyncQueueRepository], [HouseholdRepository] and
/// [GameCollectionRepository] that `UserSessionScopeInstaller` registers, and
/// the two remotes the network installer registers per server, which the
/// user-scope container view falls through to. So it must run after
/// `UserSessionScopeInstaller` in whichever list holds it.
///
/// ## Nothing here may throw
///
/// A throw from [install] aborts activation, and the shell converges that to
/// a sign-out. A missing collaborator therefore registers nothing: the
/// create route then reads as unavailable, which is the truth, rather than
/// failing the sign-in. No shipping composition reaches that guard; a
/// container assembled by hand, in a test, does.
///
/// ## Whose session it sends as (#432)
///
/// Where the server scope has a [SessionIdentityGuard] — web — the sender is
/// a [SessionConfirmingSender], which asks before each delivery whether the
/// session is still this user's. Native has none and gets the sender bare.
class SyncSenderInstaller implements UserScopeInstaller {
  const SyncSenderInstaller();

  static final BgeLogger _log = BgeLogger('bge.sync.sender.install');

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (!container.isRegistered<SyncQueueRepository>() ||
        !container.isRegistered<HouseholdRepository>() ||
        !container.isRegistered<HouseholdRemoteDataSource>() ||
        !container.isRegistered<GameCollectionRepository>() ||
        !container.isRegistered<GameCollectionRemoteDataSource>()) {
      _log.debug(
        'No queue, cache or client to send through on this server; '
        'skipping the sender',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final SyncOperationSender sender = SyncOperationSenderImpl(
      queue: container.get<SyncQueueRepository>(),
      households: container.get<HouseholdRepository>(),
      householdRemote: container.get<HouseholdRemoteDataSource>(),
      collection: container.get<GameCollectionRepository>(),
      collectionRemote: container.get<GameCollectionRemoteDataSource>(),
    );

    // Nothing to dispose: it holds no resources of its own, and what it
    // writes through goes with the session.
    container.registerSingleton<SyncOperationSender>(
      container.isRegistered<SessionIdentityGuard>()
          ? SessionConfirmingSender(
              inner: sender,
              guard: container.get<SessionIdentityGuard>(),
              userId: userId,
            )
          : sender,
    );
  }
}
