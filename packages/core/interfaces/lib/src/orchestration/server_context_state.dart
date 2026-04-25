/// Lifecycle states a [ServerContext] transitions through.
///
/// Valid transitions:
/// ```
/// initializing → active          (first activation)
/// active → backgrounding         (user switches server; co-active window begins)
/// backgrounding → active         (user switches back within timeout)
/// backgrounding → monitoring     (timeout expires or battery threshold)
/// monitoring → active            (user re-activates)
/// any → disposed                 (explicit disconnect or fatal error)
/// ```
///
/// [transitioning] is a guard state held during async state changes to
/// prevent concurrent mutation.
enum ServerContextState {
  /// Context is being constructed; dependencies initialising.
  initializing,

  /// Full foreground connection. WS open, DB open, all repos live.
  active,

  /// Co-active window after the user switched away. WS and DB remain open
  /// for the configured backgrounding timeout. In-flight and new operations
  /// are still allowed. Transitions to [monitoring] on timeout.
  backgrounding,

  /// Passive background connection. WS closed, DB closed. Notifications
  /// arrive via OS push (post-MVP) and are written as root-DB summaries only.
  monitoring,

  /// Async state change in progress. No operations accepted.
  transitioning,

  /// Context disposed. Must not be used.
  disposed,
}
