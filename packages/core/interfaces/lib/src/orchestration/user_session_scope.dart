/// Lifecycle seam for a server's per-user dependency scope (#135).
///
/// Per-server scopes activate at boot, before sign-in (#128), so any
/// singleton whose state is keyed to the current user must not live for the
/// scope's whole life: a live `watch*` subscription that outlived a
/// same-server sign-out → sign-in would keep serving the previous user's
/// rows. This seam scopes those services to the *user session* instead — a
/// child scope of the per-server scope, activated when a user authenticates
/// and deactivated when that authentication ends.
///
/// ## Where it lives
///
/// Resolved from the active server's `DependencyContainer`, like any other
/// per-server service:
///
/// ```dart
/// final scope = active.container.get<UserSessionScope>();
/// await scope.activate(session.user.id);
/// ```
///
/// - **Native**: registered by `ServerContextImpl` during context
///   activation; [activate] pushes the user scope and runs the composed
///   `UserScopeInstaller`s, [deactivate] disposes it.
/// - **Web** (#137): `bootstrapWebServerScope` registers a
///   `ContainerUserSessionScope` over the single origin-scoped container,
///   driving the same `UserScopeHost` its container facade resolves through.
///
/// A composition that registers no [UserSessionScope] — one with no per-user
/// services to install, and shell tests that provide none — is read by the
/// shell as "no per-user services here", and the scope step is skipped.
///
/// The shell's auth listener is the single intended caller: it activates on
/// any transition into the authenticated state and deactivates on any
/// transition out of it — explicit sign-out *and* mid-session
/// authentication loss (token expiry) both end the session scope.
///
/// ## Scoping semantics
///
/// User identity is per-server. [userId] is the id the *current server*
/// assigned; the same person on two servers holds two independent session
/// scopes with distinct ids, and nothing in one is visible to the other.
///
/// ## Contract
///
/// - [activate] with the [userId] already active is a no-op. [activate]
///   with a *different* user id first deactivates the existing session
///   scope, then builds the new one — a missed deactivation can't leak the
///   prior user's services.
/// - [activate] throws [StateError] when the backing server scope cannot
///   host a session (e.g. the native context is not in its active state);
///   this signals a wiring bug, not a user-facing state.
/// - If building the scope fails, the partial scope is discarded, the
///   per-server scope is untouched, and the error propagates; a later
///   [activate] retries from clean state.
/// - [deactivate] is idempotent and never throws for "nothing to do";
///   disposing the scope runs every `dispose:` callback its installers
///   registered, which must close vended streams (**close**, not error — the
///   locked #135 contract) so live subscriptions stop delivering the
///   departing user's data without injecting errors into UI being unmounted.
/// - Implementations serialize [activate]/[deactivate]; overlapping calls
///   cannot interleave scope mutations.
abstract interface class UserSessionScope {
  /// The user id of the currently active session scope, or null when none
  /// is active.
  String? get activeUserId;

  /// Builds the per-user scope for [userId], replacing any existing session
  /// scope for a different user.
  Future<void> activate(String userId);

  /// Tears the current per-user scope down, disposing every service
  /// registered in it. A no-op when no session scope is active.
  Future<void> deactivate();
}
