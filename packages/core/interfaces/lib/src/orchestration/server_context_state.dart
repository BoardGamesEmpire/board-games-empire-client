/// Lifecycle states a ServerContext transitions through based on its role
/// in the orchestrator's resource allocation model
enum ServerContextState {
  /// Context is being constructed and dependencies are initializing
  initializing,

  /// Context is the active foreground server with full resource allocation
  active,

  /// Context is monitoring in background with minimal resource allocation
  monitoring,

  /// Context is transitioning between states and should not process requests
  transitioning,

  /// Context has been disposed and should not be used
  disposed,
}
