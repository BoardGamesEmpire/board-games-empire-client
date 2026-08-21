import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import '../repositories/game_collection_repository_impl.dart';
import '../repositories/household_repository_impl.dart';
import '../repositories/sync_queue_repository_impl.dart';

/// [UserScopeInstaller] for the user-session scope (#39, #135, #150).
///
/// Registers the per-user [SyncQueueRepository], [HouseholdRepository] and
/// [GameCollectionRepository] into the **user-session scope** — the
/// per-user child of the per-server scope, pushed on sign-in and popped on
/// any transition out of the authenticated state (#135). All three are
/// keyed to the current user, so scoping them to the session guarantees a
/// live query can never outlive a user change: popping the scope disposes
/// them, and each closes every vended `watch*` stream from its dispose
/// path. For the sync queue and the collection repository the user keying
/// is **data-scoped**, not merely object-scoped (#147, #150): rows carry
/// the owning user's id and every read/write filters on it, so a scope
/// built for one user cannot observe, mutate or drain another user's data.
///
/// ### Naming (#150)
///
/// Renamed from `HouseholdScopeInstaller`: it never registered only
/// household concerns — the sync queue is not household-specific, and the
/// collection repository is not either. What its registrations actually
/// share is the **user session**, so that is what it is named for. They
/// are grouped in one installer rather than split per feature because they
/// share both a resource (the per-server [ServerDatabase]) and a
/// dependency edge — the collection repository takes the very
/// [SyncQueueRepository] instance registered here, which a split would turn
/// into a cross-installer ordering constraint.
///
/// All three depend on resources the per-server installers register — the
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
class UserSessionScopeInstaller implements UserScopeInstaller {
  const UserSessionScopeInstaller();

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
    String userId,
  ) async {
    final db = container.get<ServerDatabase>();
    final clock = container.get<ClockService>();
    final authRepository = container.get<AuthRepository>();

    // User-scoped (#147): the session's user id is stamped on every
    // enqueue and filters every read/write, so this repository can never
    // see or touch another user's rows in the server-wide table. Fixed at
    // construction (not a lazy provider): the instance is disposed on
    // every authentication transition, so it cannot carry a stale id.
    final syncQueue = SyncQueueRepositoryImpl(db, clock, userId: userId);
    container.registerSingleton<SyncQueueRepository>(
      syncQueue,
      // Close-on-teardown (#135, folded #138 item 1): scope deactivation
      // disposes the repository, which closes every vended
      // watchPendingCount stream — a subscription taken under this user
      // stops delivering (even the frozen count) after the scope pops.
      dispose: (_) => syncQueue.onDispose(),
    );

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

    // User-scoped like the queue above, and for the same reason (#150):
    // every read, write and stream filters on this id. It takes the
    // `syncQueue` instance directly — not a container lookup — so the
    // collection cache and the outbound queue can never be one user's
    // cache paired with another's queue.
    //
    // The id is fixed at construction, deliberately **not** resolved
    // through `_resolveUserId` the way the household repository's is.
    //
    // Note what that provider does and does not buy. The scope pop is
    // asynchronous — the shell fires it unawaited on the auth transition —
    // so between an authentication loss and the pop landing, an in-flight
    // caller holding this instance can still complete a write. The lazy
    // provider makes such a write throw; the fixed id lets it land under
    // the departing user's own id. Two properties decide which is right
    // here:
    //
    // 1. It cannot be a *cross-user* write. A different user's session
    //    cannot appear over this one — `activateUserSession` tears the
    //    previous scope down before building the next — so the only data
    //    reachable in that window is the same user's own, and a stale
    //    reference afterwards throws via `checkNotDisposed()`. Pinned by
    //    the missed-pop case in
    //    `test/composition/user_session_acceptance_test.dart`.
    // 2. A collection write and its queue entry are **one transaction**,
    //    and `SyncQueueRepositoryImpl` is fixed-id by the same #147
    //    reasoning. A lazy provider here would reject the collection half
    //    of a write whose queue half has no such check — one transaction
    //    under two identity rules, which is worse than a late write of the
    //    user's own edit that offline-first semantics already accept.
    //
    // The household repository is the deliberate exception: its actions
    // are foreground and gated behind the auth state, so #128 chose loud
    // failure there. If that window should fail loudly for offline writes
    // too, the fix belongs to the queue and this repository together, not
    // to this registration alone.
    final collections = GameCollectionRepositoryImpl(
      db: db,
      syncQueue: syncQueue,
      currentUserId: userId,
      clock: clock,
    );
    container.registerSingleton<GameCollectionRepository>(
      collections,
      // Close-on-teardown (#135, #138): watchCollection/watchEntry vend
      // Drift streams tied to the per-server database, which outlives this
      // scope. Without this callback a subscription taken under one user
      // would keep emitting that user's frozen rows after sign-out.
      dispose: (_) => collections.onDispose(),
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
