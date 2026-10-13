import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import 'sync_queue_drain.dart';

/// Starts the sync queue drain when a user session activates (#121).
///
/// Native only, for now: `buildNativeUserScopeInstallers` holds it, after
/// both hydrate installers and after [SyncSenderInstaller], whose sender it
/// runs. Composing it on web needs a Web Lock and a check of whose session
/// is sending, and that is #447.
///
/// ## When it runs
///
/// - **Once at install**, unawaited, as both hydrates start: work a
///   previous session left queued goes out without waiting for a trigger.
/// - **Whenever the session's [SessionRehydrator] runs a pass** and the
///   drain reports itself stale: a connectivity edge, an app resume, the
///   household list's entry, and #311's backoff once it exists. Registered
///   after both hydrates, so each pass runs it after them, though each
///   entry's failure is isolated, so "after" is not "after a successful".
///
/// Either way it can confirm a removal while a collection hydrate's page is
/// in flight. That hydrate merges with [GameCollectionRepository.removalMark],
/// so the entry stays removed.
///
/// Nothing wakes it on an enqueue: the inline create sends its own op, and
/// a wake would race that send for the claim.
///
/// ## Lifetime
///
/// The drain is registered in the session scope with a `dispose:` that
/// closes it, so the scope's teardown on sign-out, session loss, a server
/// switch or a suspend stops it between ops. A pass already sending is not
/// awaited; the repositories it writes through go with the same scope, and
/// its acknowledgement is retried after the claim runs out.
///
/// ## A refused session
///
/// A 401 asks the [AuthRepository], when the composition has one, whether
/// the session still stands, once per pass. Only the session endpoint signs
/// anyone out, so without this a session revoked mid-session would leave an
/// app that looks signed in with a drain that has stopped.
///
/// ## Nothing here may throw
///
/// A throw from [install] aborts activation, which signs the user out. So
/// the pass is unawaited, and a missing sender or queue starts nothing.
class SyncQueueDrainInstaller implements UserScopeInstaller {
  /// [now] overrides the device clock the drain measures cooldowns on.
  /// Production leaves it null.
  const SyncQueueDrainInstaller({this.now});

  static final BgeLogger _log = BgeLogger('bge.sync.drain.install');

  /// See the constructor. Null is the device clock.
  final DateTime Function()? now;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (!container.isRegistered<SyncOperationSender>() ||
        !container.isRegistered<SyncQueueRepository>()) {
      _log.debug(
        'No sender or queue on this server; skipping the drain',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final auth = container.isRegistered<AuthRepository>()
        ? container.get<AuthRepository>()
        : null;
    final drain = SyncQueueDrain(
      queue: container.get<SyncQueueRepository>(),
      sender: container.get<SyncOperationSender>(),
      // A definitive "no session" signs the user out through the auth
      // layer's own path; the queue survives it (#98).
      revalidateSession: auth?.getSession,
      now: now,
    );
    container.registerSingleton<SyncQueueDrain>(
      drain,
      dispose: (d) => d.close(),
    );

    if (container.isRegistered<SessionRehydrator>()) {
      container.get<SessionRehydrator>().register(
        'sync_queue',
        isStale: () => drain.isStale,
        run: drain.drain,
      );
    }

    unawaited(drain.drain());
  }
}
