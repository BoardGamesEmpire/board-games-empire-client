/// Answers whether the session the server will see is still the user a
/// per-user scope belongs to (#432).
///
/// On web every tab shares one session cookie while each holds its own
/// user scope. A sign-in in another tab moves the cookie to another user
/// under a tab that goes on presenting the first, and every request that tab
/// sends then acts as the second: a hydrate writes the second user's rows
/// into the first's cache, and a create is owned by one user on the server
/// and another here.
///
/// So the work that sends as the session asks first: the household and
/// collection hydrates before each pass, and the session's sync sender
/// before each delivery. Anything but [SessionConfirmation.confirmed] means
/// abandon this attempt. It is not a sign-out — whatever found the mismatch
/// has already moved the auth state, and the shell switches users from
/// there.
///
/// ## Where it is registered
///
/// In the **server** scope, by web's network composition, and resolved
/// through the user-scope view's fall-through. Native registers none: a
/// native session is its own stored token, which no other process can swap.
/// Callers treat an absent guard as confirmed.
abstract interface class SessionIdentityGuard {
  /// Whether the session is [userId]'s.
  ///
  /// Never throws: a question it cannot answer is
  /// [SessionConfirmation.unanswered].
  Future<SessionConfirmation> confirm(String userId);
}

/// What a [SessionIdentityGuard] found (#432).
///
/// The two refusals are kept apart because the sync sender reports them
/// differently: one is about the session, the other about the network.
enum SessionConfirmation {
  /// The session is the user's.
  confirmed,

  /// The session is not the user's: another user's, or none at all.
  notThisUser,

  /// Whose session it is could not be asked, because the server could not
  /// be reached, say. Sending anyway would risk the write this exists to
  /// stop, so it is a refusal too, and the work that asked retries on its
  /// next trigger.
  unanswered,
}
