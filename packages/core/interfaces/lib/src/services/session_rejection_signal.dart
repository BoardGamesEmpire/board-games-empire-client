/// Where anything that saw this server refuse the session reports it (#484).
///
/// A data endpoint's 401, the sync drain's rejected-session failure and the
/// game search socket's `auth:error` all mean the same thing: the server no
/// longer honours the session this app is presenting. Each reports here
/// instead of deciding what that means. The implementation re-reads the
/// session from the server (with concurrent reports merged) and lets auth
/// state follow the answer, so one stray 401 cannot end a live session.
///
/// Kept to one fire-and-wait method with no result, so a reporter depends on
/// nothing it doesn't use (interface segregation): callers act on auth
/// state, never on what the re-read returned.
abstract interface class SessionRejectionSignal {
  /// Completes once the auth layer has re-read the session. Never throws.
  Future<void> report();
}
