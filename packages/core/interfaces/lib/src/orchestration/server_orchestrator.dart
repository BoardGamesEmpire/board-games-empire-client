import 'server_context.dart';

/// Coordinates lifecycle and state transitions across multiple server contexts
/// while enforcing resource capacity constraints and maintaining exactly one
/// active foreground context
abstract class ServerOrchestrator {
  /// Maximum number of servers that can be simultaneously monitored for
  /// background notifications and state updates
  int get maxMonitoringCapacity;

  /// Current number of servers in active or monitoring states consuming
  /// orchestrator resources
  int get currentMonitoredCount;

  /// Identifier of the currently active foreground server, or null if no
  /// server is active (only possible during initialization)
  String? get activeServerId;

  /// Whether the orchestrator has completed initialization and is ready
  /// to process connection requests
  bool get isInitialized;

  /// Initializes the orchestrator by loading server configurations from
  /// repository and restoring runtime contexts for connected servers
  ///
  /// Throws [StateError] if called multiple times without disposal
  Future<void> initialize();

  /// Transitions a disconnected server to monitoring or active state by
  /// instantiating its ServerContext and establishing network connections
  ///
  /// If this is the first connected server or if makeActive is true, the
  /// server becomes active. Otherwise it enters monitoring state.
  ///
  /// Throws [ServerCapacityExceededException] when attempting to connect
  /// beyond the monitoring capacity limit
  /// Throws [ServerNotFoundException] if serverId doesn't exist
  /// Throws [StateError] if server is already connected
  Future<void> connectServer(String serverId, {bool makeActive = false});

  /// Transitions a monitored or active server to disconnected state by
  /// disposing its ServerContext and closing network connections
  ///
  /// If disconnecting the currently active server, prompts user to select
  /// a replacement or leaves no active server if this was the last connected
  /// server
  ///
  /// Throws [ServerNotFoundException] if serverId doesn't exist
  /// Throws [StateError] if server is already disconnected
  Future<void> disconnectServer(String serverId);

  /// Changes which server operates as the active foreground context while
  /// transitioning the previous active server to monitoring state
  ///
  /// This operation suspends the current active context by flushing pending
  /// operations and downgrading network connections before activating the
  /// target context with full foreground resource allocation
  ///
  /// Throws [ServerNotFoundException] if targetServerId doesn't exist
  /// Throws [StateError] if target server is disconnected
  Future<void> switchActiveServer(String targetServerId);

  /// Retrieves the ServerContext for a specific server if it exists in
  /// active or monitoring state, returning null for disconnected servers
  /// that have no instantiated context
  ServerContext? getContext(String serverId);

  /// Retrieves the currently active foreground ServerContext, throwing if
  /// no server is active which should only occur during initialization
  /// before the first server is connected
  ///
  /// Throws [StateError] if no active server exists
  ServerContext getActiveContext();

  /// Stream emitting the active ServerContext whenever the active server
  /// changes through switching or connection state transitions
  ///
  /// Subscribers receive the current active context immediately if one exists,
  /// then receive updates on each activation event
  Stream<ServerContext> watchActiveContext();

  /// Stream emitting current monitored count whenever servers connect or
  /// disconnect, enabling UI elements to reactively enable or disable
  /// connection actions based on capacity availability
  Stream<int> watchMonitoredCount();

  /// Determines whether connecting an additional server is possible given
  /// current capacity utilization, providing a synchronous check that UI
  /// can use to enable or disable connection buttons
  bool canConnect();

  /// Disposes all server contexts and releases orchestrator resources in
  /// preparation for application shutdown or orchestrator replacement
  Future<void> dispose();
}
