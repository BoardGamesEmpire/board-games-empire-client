import 'package:models/domain.dart';

import 'server_context.dart';

/// Coordinates lifecycle and atomic state transitions across all server
/// contexts, enforcing capacity constraints and maintaining exactly one
/// active foreground context at a time.
///
/// The orchestrator is the single authority over [ServerContext] creation
/// and destruction. Blocs and UI components interact with it indirectly
/// through streams and the active context's [DependencyContainer].
abstract class ServerOrchestrator {
  /// User-configured maximum number of simultaneously connected servers
  /// (active + backgrounding + monitoring). Sourced from [DevicePreferences].
  int get maxMonitoringCapacity;

  /// Number of servers currently in active, backgrounding, or monitoring state.
  int get currentConnectedCount;

  /// Local server id of the currently active foreground server.
  /// Null only before [initialize] completes.
  String? get activeServerId;

  /// The [ServerConfig] of the currently active server; null when no
  /// server is active (#37).
  ///
  /// A read-only snapshot taken when the server was connected. Commits
  /// together with [activeServerId] and the [watchActiveContext]
  /// emission, so a listener delivered an active-context event reads a
  /// config consistent with that event. Backed by parallel config
  /// bookkeeping in the implementation (a snapshot map keyed by
  /// [activeServerId]), kept in lockstep with the live contexts.
  ///
  /// Note the native `ActiveServerScope` adapter does not read this getter:
  /// it builds its `ActiveServer` value from the active [ServerContext]'s
  /// own `config`. Both are connect-time snapshots of the same config.
  ServerConfig? get activeConfig;

  /// Whether [initialize] has completed successfully.
  bool get isInitialized;

  /// Whether a new server can be connected without exceeding capacity.
  bool canConnect();

  /// Loads server configurations from the repository and restores contexts
  /// for any servers that were connected at last shutdown.
  ///
  /// Throws [StateError] if called more than once without disposal.
  Future<void> initialize();

  /// Persists a newly discovered server and connects it as the active
  /// foreground server, atomically from the caller's perspective (#36).
  ///
  /// The caller (the server-add flow) has already fetched and vetted
  /// [identity] — well-known discovery and version negotiation (#13)
  /// happen *before* this call; the orchestrator applies no policy of
  /// its own beyond its usual capacity rules.
  ///
  /// On any failure after the repository add (capacity, activation), the
  /// persisted config is removed again so a failed onboarding never
  /// leaves a zombie entry behind.
  ///
  /// Returns the persisted [ServerConfig]'s local id.
  ///
  /// Throws [DuplicateServerException] if [serverUrl] or [bgeServerId]
  /// is already registered.
  /// Throws [ServerCapacityExceededException] if at capacity.
  Future<String> addAndActivateServer({
    required String displayName,
    required String serverUrl,
    required String bgeServerId,
    required ServerIdentity identity,
  });

  /// Creates a context for a disconnected server and connects it.
  ///
  /// If [makeActive] is true or no server is currently active, the server
  /// becomes [ServerContextState.active]. Otherwise it enters
  /// [ServerContextState.monitoring].
  ///
  /// Throws [ServerCapacityExceededException] if at capacity.
  /// Throws [ServerNotFoundException] if [serverId] is not in the repository.
  /// Throws [StateError] if server is already connected.
  Future<void> connectServer(String serverId, {bool makeActive = false});

  /// Disposes the context for a connected server and marks it disconnected.
  ///
  /// If disconnecting the active server and other connected servers exist,
  /// the most recently active among them becomes the new active server.
  ///
  /// Throws [ServerNotFoundException] if [serverId] is not in the repository.
  /// Throws [StateError] if server is already disconnected.
  Future<void> disconnectServer(String serverId);

  /// Backgrounds the current active server and activates [targetServerId].
  ///
  /// - Transitions the current active context to [ServerContextState.backgrounding]
  ///   and starts the backgrounding timer for it.
  /// - Transitions [targetServerId] from monitoring or backgrounding to
  ///   [ServerContextState.active], cancelling its backgrounding timer if present.
  ///
  /// Throws [ServerNotFoundException] if [targetServerId] is not connected.
  /// Throws [StateError] if [targetServerId] is already active or disconnected.
  Future<void> switchActiveServer(String targetServerId);

  /// Returns the context for [serverId], or null if disconnected.
  ServerContext? getContext(String serverId);

  /// Returns the currently active context.
  /// Null only before [initialize] completes or if no server is active.
  ServerContext? getActiveContext();

  /// Stream emitting the active [ServerContext] whenever it changes.
  /// Emits null if no server is active.
  Stream<ServerContext?> watchActiveContext();

  /// Stream emitting the full map of connected contexts on any change.
  Stream<Map<String, ServerContext>> watchContexts();

  /// Disposes all contexts and resets orchestrator state.
  Future<void> dispose();
}
