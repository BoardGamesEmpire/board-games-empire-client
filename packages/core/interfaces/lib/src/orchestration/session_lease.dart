/// Says whether a user session is still live.
///
/// Live from the moment its user-session scope opens until the session is
/// ended: when `UserSessionScope.deactivate` is called, or the scope closes
/// some other way, whichever comes first. Resolved from the active container
/// like any user-scoped service.
///
/// Something that may outlast its session (a late outcome, #694) captures the
/// lease and asks before acting.
abstract interface class SessionLease {
  /// Whether the session this lease belongs to is still open.
  ///
  /// True until its session is ended, then false for good: a later session
  /// gets a new lease rather than reviving this one.
  bool get isLive;
}

/// The lease for compositions that register no `UserSessionScope`, which
/// today means shell tests: both platforms register one in every server
/// scope, and a route built there before a session opens gets an ended
/// lease, not this one. There is no session here to end, so it is always
/// live.
final class UnscopedSessionLease implements SessionLease {
  const UnscopedSessionLease();

  @override
  bool get isLive => true;
}
