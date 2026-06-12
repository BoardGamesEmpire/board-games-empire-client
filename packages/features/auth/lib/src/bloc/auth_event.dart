import 'package:equatable/equatable.dart';
import 'package:interfaces/repositories.dart';
import 'package:observability/observability.dart';

sealed class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

final class AuthSessionCheckRequested extends AuthEvent {
  const AuthSessionCheckRequested();
}

final class AuthSignInRequested extends AuthEvent {
  const AuthSignInRequested({required this.email, required this.password});
  final String email;
  final String password;

  @override
  List<Object?> get props => [email, password];

  /// Redacted stringification.
  ///
  /// [password] stays in [props] for equality (tests rely on full
  /// structural equality of events), but Equatable's default
  /// [toString] honours `EquatableConfig.stringify` — if a host
  /// app or test harness sets that flag, the password would leak
  /// into Bloc transition logs, observer output, and test-failure
  /// matcher diffs. Overriding [toString] here makes the leak
  /// impossible regardless of EquatableConfig.
  ///
  /// [email] is partially redacted via [Redaction.redactEmail] — first and
  /// last char of each dot-separated local-part segment is kept,
  /// middle is masked, domain is preserved. A debug reader can
  /// still correlate sign-in attempts by the same user (the
  /// pattern is deterministic) but doesn't see usable PII in
  /// plain.
  @override
  String toString() =>
      'AuthSignInRequested('
      'email: ${Redaction.redactEmail(email)}, '
      'password: <redacted>)';
}

final class AuthRegisterRequested extends AuthEvent {
  const AuthRegisterRequested({
    required this.email,
    required this.password,
    required this.username,
    this.firstName,
    this.lastName,
  });
  final String email;
  final String password;
  final String username;
  final String? firstName;
  final String? lastName;

  @override
  List<Object?> get props => [email, password, username, firstName, lastName];

  /// Redacted stringification — see [AuthSignInRequested.toString]
  /// for the rationale on the password and email redactions.
  ///
  /// [username], [firstName], and [lastName] are partially redacted
  /// via [Redaction.redactName] — first and last char preserved, middle
  /// masked. Null name fields render as the literal `null` so a
  /// debug reader can tell at a glance which optional fields were
  /// supplied. As with the email, the redaction is a debug-readability
  /// vs incidental-exposure compromise: a determined attacker
  /// correlating multiple events or combining with other context
  /// can still reverse short names, but the casual log or
  /// test-failure diff doesn't expose usable PII in plain.
  @override
  String toString() {
    // Locals for null-promotion inside the conditional expressions.
    final fn = firstName;
    final ln = lastName;
    return 'AuthRegisterRequested('
        'email: ${Redaction.redactEmail(email)}, '
        'password: <redacted>, '
        'username: ${Redaction.redactName(username)}, '
        'firstName: ${fn == null ? 'null' : Redaction.redactName(fn)}, '
        'lastName: ${ln == null ? 'null' : Redaction.redactName(ln)})';
  }
}

final class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

/// Internal — mirrors repository auth-stream changes into the bloc.
final class AuthRepositoryStateChanged extends AuthEvent {
  const AuthRepositoryStateChanged(this.repoState);
  final AuthState repoState;

  @override
  List<Object?> get props => [repoState];

  /// Type-only stringification.
  ///
  /// [repoState] can be [AuthStateAuthenticated] and carry a
  /// session token, refresh token, or user metadata; printing the
  /// full state via Equatable's stringify path (or any default
  /// `'$repoState'` interpolation) would leak credentials and PII
  /// into Bloc logs and test-failure output. The runtime type is
  /// the only part of this event worth surfacing in logs anyway —
  /// it tells you which transition just fired, which is what a
  /// reader of the trail actually needs.
  @override
  String toString() => 'AuthRepositoryStateChanged(${repoState.runtimeType})';
}
