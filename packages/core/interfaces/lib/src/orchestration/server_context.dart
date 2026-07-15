import 'package:models/domain.dart';

import 'dependency_container.dart';
import 'server_context_state.dart';

/// Encapsulates the isolated dependency injection scope, storage, networking,
/// and lifecycle state for a single BGE server instance.
///
/// State is owned and mutated exclusively by [ServerOrchestrator]. External
/// consumers observe via [watchState] and retrieve services via [container].
abstract class ServerContext {
  /// Local server id matching the [ServerConfig.id] this context represents.
  String get serverId;

  /// The [ServerConfig] this context was created for.
  ///
  /// A connect-time snapshot, retained for the context's whole life. The
  /// authoritative source of the active server's identity/display name for
  /// the native `ActiveServerScope` adapter, which reads it straight off the
  /// live active context (`getActiveContext().config`) — so its snapshot
  /// cannot drift from the context it came from (#37).
  ///
  /// ([ServerOrchestrator.activeConfig] is a separate getter backed by its
  /// own snapshot map; the implementation keeps that map in lockstep with
  /// the contexts.) Sufficient while no rename-server flow exists; a stale
  /// [ServerConfig.connectionState] here is not read off this path.
  ServerConfig get config;

  /// Current lifecycle state.
  ServerContextState get state;

  /// Isolated dependency injection container for this server's services.
  /// Retrieve dependencies via `context.container.get<T>()`.
  DependencyContainer get container;

  /// Transitions to [ServerContextState.active].
  ///
  /// Opens the per-server DB and WebSocket connection.
  /// Throws [StateError] if current state is not [ServerContextState.monitoring],
  /// [ServerContextState.backgrounding], or [ServerContextState.initializing].
  Future<void> activate();

  /// Transitions to [ServerContextState.backgrounding].
  ///
  /// Retains all open resources. Called by the orchestrator when the user
  /// switches to another server. The backgrounding timer is managed by the
  /// orchestrator, which calls [suspend] when it expires.
  /// Throws [StateError] if current state is not [ServerContextState.active].
  Future<void> background();

  /// Transitions to [ServerContextState.monitoring].
  ///
  /// Closes the WebSocket and per-server DB. Only the root DB summary path
  /// remains live for incoming OS push notifications (post-MVP stub).
  /// Throws [StateError] if current state is not [ServerContextState.backgrounding].
  Future<void> suspend();

  /// Disposes all resources and transitions to [ServerContextState.disposed].
  ///
  /// Idempotent — safe to call on an already-disposed context.
  Future<void> dispose();

  /// Stream of lifecycle state changes. Replays the current state on subscribe.
  Stream<ServerContextState> watchState();
}
