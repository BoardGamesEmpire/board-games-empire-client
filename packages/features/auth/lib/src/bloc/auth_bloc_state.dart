import 'package:equatable/equatable.dart';
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

final class AuthAuthenticated extends AuthBlocState {
  const AuthAuthenticated({required this.session});
  final AuthResponse session;

  @override
  List<Object?> get props => [session];
}

final class AuthUnauthenticated extends AuthBlocState {
  const AuthUnauthenticated();
}

/// The startup session check could not be completed (#37).
///
/// The repository's `getSession` never throws for an auth rejection — a
/// 401 clears the stored token and returns null (→
/// [AuthUnauthenticated]) — so reaching this state means the stored
/// session is INDETERMINATE (offline, timeout, server error), not
/// rejected. The auth gate renders a retryable "can't reach the server"
/// view, never the sign-in form (which would wrongly suggest the stored
/// session is gone); retry re-dispatches the session check. True
/// offline-first restore (enter on a cached session, revalidate on
/// reconnect) is #98.
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
