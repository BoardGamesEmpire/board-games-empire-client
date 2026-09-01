import 'package:models/dto.dart';
import 'package:models/domain.dart';

/// Per-server authentication repository.
///
/// Scoped to a single BGE server. All endpoint URLs are sourced from the
/// [ServerIdentity] injected at construction — never hardcoded.
///
/// Mobile/desktop: backed by [AuthRepositoryImpl] with [TokenStorageService].
/// Web: backed by [WebAuthRepositoryImpl] using browser-managed httpOnly
/// cookies.
abstract class AuthRepository {
  /// Signs in with email and password.
  ///
  /// Throws [AuthInvalidCredentialsException] for 401/403.
  /// Throws [AuthNetworkException] for connectivity failures.
  /// Throws [AuthServerException] for unexpected server errors, including a
  /// credential grant the server then reports no session for.
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  });

  /// Registers a new account and signs in.
  ///
  /// Throws [AuthRegistrationDisabledException] if registration is disabled.
  /// Throws [AuthEmailAlreadyExistsException] if the email is taken.
  /// Throws [AuthNetworkException] for connectivity failures.
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String username,
    String? firstName,
    String? lastName,
  });

  /// Validates the current session with the server.
  ///
  /// Returns null only when the server gives a **definitive** negative — a
  /// 401, a 403, or BetterAuth's 200-with-null-body "no session" — in which
  /// case the stored session material is cleared and the in-memory state
  /// transitions to [AuthStateUnauthenticated]. Also returns null, without
  /// touching storage or state, when the caller signed out while the request
  /// was in flight: the newer intent wins.
  ///
  /// Throws (rather than returning null) whenever the answer is
  /// **indeterminate**: [AuthNetworkException] for transport failures, and
  /// [AuthServerException] for any other non-2xx. This split is what lets
  /// the bloc layer distinguish "the session is gone" (→ sign-in form) from
  /// "we could not check" (→ offline restore or the retry view, #37/#98).
  /// A null return for an indeterminate outcome would land the user on the
  /// sign-in form and wrongly imply the stored session was rejected.
  ///
  /// On success, updates the persisted expiry — the only path that produces
  /// a **server-confirmed** expiry (see [getCachedSession]).
  Future<AuthResponse?> getSession();

  /// Signs out and clears the local session.
  ///
  /// Best-effort server call. The repository's in-memory auth state
  /// ALWAYS transitions to [AuthStateUnauthenticated] — unconditionally,
  /// even when clearing the persisted session material fails. In that
  /// case an [AuthSignOutPersistenceException] is thrown, but only after
  /// the state transition has been observed by [watchAuthState], so the
  /// stream can never re-assert a session the user just ended (#37). The
  /// residual risk of a failed persisted clear is the surviving token
  /// restoring a session on the next cold start, where sign-out can be
  /// repeated.
  Future<void> signOut();

  /// Returns the locally cached session without a network call, or null
  /// when there is no session this device can vouch for offline.
  ///
  /// A **pure read** — it never mutates the in-memory auth state. Use
  /// [restoreCachedSession] when the caller intends the cached session to
  /// become the process's working session.
  ///
  /// Non-null requires all of (#98):
  ///
  /// - session material is present and not latched away by a sign-out;
  /// - the expiry is **server-confirmed** — written by a successful
  ///   [getSession], never guessed at sign-in. An unconfirmed expiry is not
  ///   "unexpired", it is *unknown*, and unknown is not good enough to
  ///   enter the app on;
  /// - that expiry is in the future by the per-server [ClockService] —
  ///   expiry lives on the *server's* timeline, so it wants the
  ///   skew-corrected reading;
  /// - a persisted user snapshot exists (the per-(server, user) scope in
  ///   #135 cannot activate without a real user id);
  /// - the *device's* clock is not provably wrong — it has not moved
  ///   backwards past the moment the material was persisted. This one is
  ///   evaluated against the raw device clock, not the corrected one:
  ///   mixing the two makes a lagging device fail the check for a window
  ///   equal to its own skew after every successful [getSession].
  ///
  /// An in-memory authenticated session takes precedence and is returned
  /// as-is, so a signed-in caller is never told "not authenticated" merely
  /// because the persisted expiry was never confirmed.
  ///
  /// ## The purity clause binds every platform (#275)
  ///
  /// This used to carry a sanction of web delegating the whole method to
  /// [getSession], which contradicted the two clauses above: [getSession]
  /// takes a network call and mutates the in-memory auth state on every
  /// outcome. The sanction is gone and the clauses stand — a "pure read
  /// without a network call" means that everywhere.
  ///
  /// What differs by platform is only how much *persisted* material there
  /// is to read. Web has none: httpOnly cookies are opaque to Dart, so
  /// every bullet in the list above is vacuous there and only the in-memory
  /// clause has anything to return. That is a narrower answer, not a
  /// different contract.
  ///
  /// Null therefore keeps its documented meaning — "no session this device
  /// can vouch for offline" — which is **not** the same as "no session
  /// exists". A caller needing the server's answer must call [getSession].
  Future<AuthResponse?> getCachedSession();

  /// Attempts an optimistic offline restore (#98): reads the cached
  /// session per [getCachedSession] and, on success, **adopts it as the
  /// in-memory auth state** with [SessionVerification.unverifiedOffline],
  /// notifying [watchAuthState] and [currentAuthState].
  ///
  /// Adoption is the point, not a side effect. Everything downstream of
  /// the repository resolves the current user from the repository's own
  /// state — most importantly the user-scoped per-server repositories,
  /// which read [currentAuthState] lazily at call time (#128). A restore
  /// that left the repository reporting [AuthStateUnknown] would put the
  /// user on the home screen while every user-scoped read failed, which
  /// is precisely the offline case this exists to serve.
  ///
  /// Returns null and leaves the state untouched when no cached session
  /// qualifies. Never throws for an absent or ineligible session; a
  /// storage fault propagates.
  ///
  /// Implementations that cannot inspect their session material offline
  /// (web, whose cookie is opaque) return null unconditionally.
  Future<AuthResponse?> restoreCachedSession();

  /// Stream of auth state changes. Replays current state on subscribe.
  Stream<AuthState> watchAuthState();

  /// Synchronous snapshot of the repository's in-memory auth state (#97)
  /// — the same value [watchAuthState] replays on subscribe.
  ///
  /// Exists for synchronous consumers that cannot await a stream, e.g.
  /// the feedback target resolver deciding per `submit`/`drain` whether
  /// the active server's transport is usable (the feedback endpoint
  /// requires an authenticated session), and the lazy current-user
  /// resolution in user-scoped per-server repositories (#128).
  /// Belt-and-braces: a session can still expire between this read and
  /// the request, which is why a 401 classifies as retryable rather than
  /// permanent. After an optimistic restore this reports
  /// [AuthStateAuthenticated] with
  /// [SessionVerification.unverifiedOffline] — authenticated as far as
  /// this device knows, unconfirmed by the server.
  AuthState get currentAuthState;
}

/// How much the current session has been confirmed by the server (#98).
///
/// Deliberately a field on [AuthStateAuthenticated] rather than a separate
/// state: every consumer's *routing* decision is identical for both values
/// — the gate shows content, the user-session scope activates, the router
/// goes to home. Only presentation differs. A separate sealed variant
/// would force every exhaustive switch to change for no behavioural gain,
/// and invites a consumer to forget that unverified still means
/// authenticated.
enum SessionVerification {
  /// The server confirmed this session on this run — a sign-in, a
  /// sign-up, or a successful `getSession`.
  verified,

  /// Restored from local material without server confirmation because the
  /// server was unreachable (#98). The session is locally valid: present,
  /// with a server-confirmed expiry that has not passed. It is *not* proof
  /// the server still accepts it — that only arrives on revalidation.
  unverifiedOffline,
}

/// Sealed hierarchy of authentication states.
///
/// ## Value equality
///
/// All three variants implement value equality:
///
/// - [AuthStateUnknown] and [AuthStateUnauthenticated]: const-no-field
///   singletons. Dart canonicalises const constructors, so two
///   `const AuthStateUnknown()` literals are already the same
///   instance and identity equality works. The explicit
///   `==`/`hashCode` overrides defend the non-const construction
///   case (e.g. a caller writing `AuthStateUnknown()` without
///   `const`) so the type alone determines equality.
/// - [AuthStateAuthenticated]: compares by `session` (an `AuthResponse`
///   — a freezed model with built-in value equality) **and**
///   `verification`. The verification field MUST participate: a
///   `unverifiedOffline → verified` transition on the same session
///   changes nothing else about the state, so an equality that ignored
///   it would make the successful revalidation invisible to every
///   value-comparing consumer downstream (#98).
///
/// Value equality matters for [AuthRepositoryStateChanged] in the
/// bloc layer: that event extends Equatable with `props =
/// [repoState]`, and Equatable's equality only works correctly if
/// `repoState`'s own `==` is value-based. Without these overrides,
/// `AuthRepositoryStateChanged(AuthStateAuthenticated(s)) ==
/// AuthRepositoryStateChanged(AuthStateAuthenticated(s))` returned
/// false for freshly-constructed instances, breaking bloc-test
/// matchers like
/// `emits(AuthRepositoryStateChanged(AuthStateAuthenticated(expectedSession)))`.
sealed class AuthState {
  const AuthState();
}

final class AuthStateUnknown extends AuthState {
  const AuthStateUnknown();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AuthStateUnknown;

  @override
  int get hashCode => (AuthStateUnknown).hashCode;
}

final class AuthStateAuthenticated extends AuthState {
  const AuthStateAuthenticated({
    required this.session,
    this.verification = SessionVerification.verified,
  });

  final AuthResponse session;

  /// Whether the server confirmed this session on this run (#98).
  /// Defaults to [SessionVerification.verified] — every pre-#98
  /// construction site reached this state through a server round trip.
  final SessionVerification verification;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuthStateAuthenticated &&
          other.session == session &&
          other.verification == verification);

  @override
  int get hashCode => Object.hash(runtimeType, session, verification);
}

final class AuthStateUnauthenticated extends AuthState {
  const AuthStateUnauthenticated();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AuthStateUnauthenticated;

  @override
  int get hashCode => (AuthStateUnauthenticated).hashCode;
}

sealed class AuthException implements Exception {
  const AuthException({required this.message, this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

final class AuthInvalidCredentialsException extends AuthException {
  const AuthInvalidCredentialsException({
    super.message = 'Invalid email or password.',
  });
}

final class AuthEmailAlreadyExistsException extends AuthException {
  const AuthEmailAlreadyExistsException({
    super.message = 'An account with this email already exists.',
  });
}

final class AuthRegistrationDisabledException extends AuthException {
  const AuthRegistrationDisabledException({
    super.message = 'Registration is currently disabled on this server.',
  });
}

final class AuthNetworkException extends AuthException {
  const AuthNetworkException({required super.message, super.cause});
}

final class AuthServerException extends AuthException {
  const AuthServerException({
    required super.message,
    this.statusCode,
    super.cause,
  });
  final int? statusCode;
}

/// The operation was overtaken by a sign-out (or another supersession of
/// the session) while it was in flight (#146).
///
/// Thrown by [AuthRepository.signIn]/[signUp] when a sign-out lands during
/// the credential grant's persist-and-reconcile window. The newer intent
/// won: state and storage already reflect the sign-out by the time this is
/// thrown. Callers should treat it as a quiet return to the unauthenticated
/// surface — NOT as a server fault; the previous behavior reported it as
/// an [AuthServerException] "server disowned the session" contract
/// violation, which pointed a user's own sign-out at the server.
final class AuthSupersededException extends AuthException {
  const AuthSupersededException({
    super.message = 'The operation was superseded by a sign-out.',
  });
}

/// Sign-out could not clear the locally persisted session material (#37).
///
/// Thrown by [AuthRepository.signOut] only AFTER the repository's
/// in-memory auth state has transitioned to [AuthStateUnauthenticated] —
/// the sign-out is effective for this process regardless, and
/// [AuthRepository.watchAuthState] can never re-assert the ended session.
/// The residual risk is the persisted token surviving until the next cold
/// start, where the restored session can be signed out again. [cause]
/// carries the underlying storage fault.
final class AuthSignOutPersistenceException extends AuthException {
  const AuthSignOutPersistenceException({
    super.message =
        'Signed out, but the stored session material could not be cleared.',
    super.cause,
  });
}
