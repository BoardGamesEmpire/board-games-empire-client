import 'package:equatable/equatable.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/dto.dart';

/// States for `AuthBloc` (#37).
///
/// Failures carry *kinds* (and diagnostic payloads excluded from
/// equality), never display strings — localization is the widget layer's
/// job, keeping the bloc free of any locale concern (#33; same convention
/// as `ServerOnboardingState`).
sealed class AuthBlocState extends Equatable {
  const AuthBlocState();

  @override
  List<Object?> get props => const [];
}

final class AuthInitial extends AuthBlocState {
  const AuthInitial();
}

/// An interactive auth operation (sign-in, register, sign-out) is in
/// flight. Rendered as inline progress by the auth form — distinct from
/// [AuthSessionCheckInProgress], which happens before any form is shown.
final class AuthLoading extends AuthBlocState {
  const AuthLoading();
}

/// The startup session check (restore) is in flight (#37).
///
/// Distinct from [AuthLoading]: during the session check no form is on
/// screen — the auth gate renders the splash, continuous with the
/// bootstrap splash. Encoding the phase in the state keeps the gate a
/// pure function of bloc state (no widget-local restore latch).
final class AuthSessionCheckInProgress extends AuthBlocState {
  const AuthSessionCheckInProgress();
}

/// The user is in. [verification] says whether the server has confirmed
/// that on this run (#98).
///
/// Verification is a field rather than a sibling state because every
/// consumer's *routing* decision is identical for both values: the gate
/// shows content, the user-session scope activates, the router goes to
/// home. Only presentation differs. A separate sealed variant would force
/// every exhaustive switch to change for no behavioural gain, and invites
/// a consumer to forget that unverified still means authenticated.
///
/// [verification] participates in [props]. It must: an
/// `unverifiedOffline → verified` transition changes nothing else about
/// the state, so an equality that ignored it would make a successful
/// revalidation invisible — both to `BlocBuilder` and to
/// `AuthBloc.emit`, which skips emitting a state equal to the current
/// one.
final class AuthAuthenticated extends AuthBlocState {
  const AuthAuthenticated({
    required this.session,
    this.verification = SessionVerification.verified,
  });

  final AuthResponse session;

  /// Defaults to [SessionVerification.verified] — every construction site
  /// other than the offline-restore path reached this state through a
  /// server round trip.
  final SessionVerification verification;

  /// Whether this session came from local material the server has not yet
  /// confirmed (#98). The one bit the presentation layer needs; nothing
  /// else about routing or gating keys off it.
  bool get isUnverifiedOffline =>
      verification == SessionVerification.unverifiedOffline;

  @override
  List<Object?> get props => [session, verification];
}

final class AuthUnauthenticated extends AuthBlocState {
  const AuthUnauthenticated();
}

/// The startup session check could not be completed AND no cached session
/// was eligible to enter on (#37, narrowed by #98).
///
/// Two things must both be true to land here, which makes this rarer than
/// it was before #98 — but not obsolete, which is why the retryable view
/// survives:
///
/// 1. The check was **indeterminate** — offline, timeout, 5xx, or an
///    unexpected fault such as a locked keychain. A rejection is never
///    indeterminate: the repository clears the material and returns null
///    for a 401, a 403, or BetterAuth's 200-with-null-body, all of which
///    yield [AuthUnauthenticated] and the sign-in form.
/// 2. No cached session qualified for optimistic entry — no session
///    material at all, an expiry the server never confirmed, a missing
///    user snapshot, a passed expiry, or a device clock that has moved
///    backwards.
///
/// The auth gate renders a retryable "can't reach the server" view, never
/// the sign-in form — which would wrongly suggest the stored session was
/// rejected. Retry re-dispatches the session check.
final class AuthSessionCheckFailed extends AuthBlocState {
  const AuthSessionCheckFailed([this.cause, this.stackTrace]);

  /// The underlying error — retained for the feedback pipeline
  /// (logging/reporting), excluded from equality so tests can match on
  /// the state alone. Never for display.
  final Object? cause;

  /// The stack trace captured at the catch site (#100). Threaded through so
  /// the centralised error log in `AuthBloc.onTransition` has a trace for
  /// the bucket that needs it most — an unexpected non-auth fault (e.g. a
  /// locked keychain). Excluded from equality (diagnostic, not identity),
  /// same as [cause].
  final StackTrace? stackTrace;
}

/// Why an interactive auth operation (sign-in / register) failed. Each
/// kind maps to one localized message in the widget layer.
sealed class AuthOperationFailure extends AuthBlocState {
  const AuthOperationFailure();
}

/// Sign-in rejected: wrong email or password (401/403).
final class AuthFailureInvalidCredentials extends AuthOperationFailure {
  const AuthFailureInvalidCredentials();
}

/// Registration rejected: the email is already taken (409). Implies the
/// email field — the widget layer attaches the localized error there.
final class AuthFailureEmailAlreadyExists extends AuthOperationFailure {
  const AuthFailureEmailAlreadyExists();
}

/// Registration rejected: the server disables sign-up.
final class AuthFailureRegistrationDisabled extends AuthOperationFailure {
  const AuthFailureRegistrationDisabled();
}

/// Connectivity failure or timeout reaching the server.
final class AuthFailureNetwork extends AuthOperationFailure {
  const AuthFailureNetwork();
}

/// Anything unanticipated (unexpected status, malformed body, …). The
/// original error is retained for the feedback pipeline, but excluded
/// from equality so tests can match on the state alone.
final class AuthFailureServer extends AuthOperationFailure {
  const AuthFailureServer([this.cause]);

  final Object? cause;
}
