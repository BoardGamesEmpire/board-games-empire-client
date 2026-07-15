import 'package:models/domain.dart';

import 'dependency_container.dart';

/// A read-only snapshot of the currently active server, as consumers
/// outside the orchestration layer see it (#37).
///
/// This is deliberately narrower than [ServerContext]: no lifecycle
/// surface (`activate` / `suspend` / `dispose`), only what the widget
/// layer and per-server service consumers actually need —
///
/// - [container] to resolve per-server services (`AuthRepository`,
///   `FeedbackTransport` in #97, …);
/// - [identity] and [displayName] for auth UI (`AuthScreen` renders the
///   strategies the server advertises and attributes the form to the
///   server by name);
/// - [serverId] for per-server bookkeeping (e.g. tagging queued feedback
///   reports in #97, keying widget rebuilds on server switches).
///
/// Values are snapshots taken when the server was connected (sourced from
/// the active [ServerContext]'s `config` on native); a rename-server flow
/// does not exist yet, so staleness is not a concern in alpha.
class ActiveServer {
  const ActiveServer({
    required this.serverId,
    required this.displayName,
    required this.identity,
    required this.container,
  });

  /// Client-local server id ([ServerConfig.id] on native).
  final String serverId;

  /// Human-readable server name, shown by auth UI for attribution.
  final String displayName;

  /// The server's last-known identity document (advertised auth
  /// strategies, endpoint paths).
  final ServerIdentity identity;

  /// The per-server dependency injection scope. Resolve per-server
  /// services via `container.get<T>()`.
  final DependencyContainer container;

  /// Value equality over the snapshot fields; the [container] compares by
  /// identity (it is a live scope, not a value). Two emissions for the
  /// same connected server therefore compare equal, letting consumers
  /// dedupe with `distinct()` if they care.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActiveServer &&
          other.serverId == serverId &&
          other.displayName == displayName &&
          other.identity == identity &&
          identical(other.container, container);

  @override
  int get hashCode =>
      Object.hash(serverId, displayName, identity, identityHashCode(container));

  @override
  String toString() =>
      'ActiveServer(serverId: $serverId, displayName: $displayName)';
}

/// The platform-neutral "which server is active" seam (#37).
///
/// The shared shell (`app_shell`) provisions per-server consumers (the
/// auth bloc, #97's feedback transport resolver, future per-server
/// services) from this interface alone — never from `kIsWeb` branches or
/// the orchestrator directly. Each platform's composition root supplies
/// the backing:
///
/// - **Native**: `OrchestratorActiveServerScope` in `core/di`, a thin
///   adapter over [ServerOrchestrator.watchActiveContext] that re-reads the
///   active [ServerContext]'s `config` on each emission.
/// - **Web** (#96): a one-shot holder emitting the single origin-scoped
///   container — web has no orchestrator by design (#31), and this seam
///   is intentionally not a degenerate one.
///
/// ## Contract
///
/// - [watchActive] **replays the current value on subscribe** (matching
///   the `watchAuthState` / `watchState` convention). This is required:
///   the underlying orchestrator stream has no replay, and the shell
///   subscribes after bootstrap has already activated a restored server —
///   without replay a returning user would never see their server.
/// - Emissions are **not** guaranteed distinct; consumers that key work
///   on the server (e.g. a bloc provider keyed by [ActiveServer.serverId])
///   should treat repeats as no-ops or apply `distinct()`.
/// - `null` means no server is active (pre-onboarding, or between a
///   disconnect and a promotion).
abstract interface class ActiveServerScope {
  /// The currently active server, or null when none is active.
  ActiveServer? get active;

  /// Stream of active-server changes. Replays the current value on
  /// subscribe.
  Stream<ActiveServer?> watchActive();
}
