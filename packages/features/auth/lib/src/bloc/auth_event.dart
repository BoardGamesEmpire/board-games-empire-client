import 'package:equatable/equatable.dart';
import 'package:interfaces/repositories.dart';

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
  /// [email] is partially redacted via [_redactEmail] — first and
  /// last char of each dot-separated local-part segment is kept,
  /// middle is masked, domain is preserved. A debug reader can
  /// still correlate sign-in attempts by the same user (the
  /// pattern is deterministic) but doesn't see usable PII in
  /// plain.
  @override
  String toString() =>
      'AuthSignInRequested('
      'email: ${_redactEmail(email)}, '
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
  /// via [_redactName] — first and last char preserved, middle
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
        'email: ${_redactEmail(email)}, '
        'password: <redacted>, '
        'username: ${_redactName(username)}, '
        'firstName: ${fn == null ? 'null' : _redactName(fn)}, '
        'lastName: ${ln == null ? 'null' : _redactName(ln)})';
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

// ── PII redaction helpers ────────────────────────────────────────────────────

/// Partial PII redaction for log/debug stringification.
///
/// Preserves the first and last character of [name] and masks the
/// middle with `*` of the original-length minus 2.
///
/// - Empty string → empty string.
/// - 1 char → `'*'`.
/// - 2 chars → `'**'`.
/// - 3+ chars → first + `'*' * (length - 2)` + last.
///
/// Examples:
/// - `John` → `J**n`
/// - `Bob` → `B*b`
/// - `Al` → `**`
/// - `X` → `*`
///
/// This is a debug-readability vs incidental-exposure compromise,
/// not strong anonymisation. The redaction is deterministic, so:
///
/// - A reader of multiple log lines for the same user sees the
///   same pattern repeatedly and can correlate events without
///   needing the full name.
/// - A determined attacker correlating multiple log lines, or
///   combining with other context (length-based guessing, known
///   user lists, etc.), can reverse most short names. If GDPR-
///   grade anonymisation is required for a particular deployment,
///   the redaction should be tightened to full mask or the
///   logging suppressed entirely at the observer layer.
String _redactName(String name) {
  if (name.isEmpty) return '';
  if (name.length <= 2) return '*' * name.length;
  return '${name[0]}${'*' * (name.length - 2)}${name[name.length - 1]}';
}

/// Partial email redaction for log/debug stringification.
///
/// Splits the local part of [email] on `.`, applies [_redactName]
/// to each segment, rejoins with `.`, and leaves the domain (the
/// `@…` suffix) entirely intact. Examples:
///
/// - `john.doe@email.com` → `j**n.d*e@email.com`
/// - `alice@example.com` → `a***e@example.com`
/// - `j@gmail.com` → `*@gmail.com`
/// - `bare-string-no-at` → treated as a name, redacted whole.
///
/// The domain is preserved because:
///
/// - It's commonly useful for debug context — at a glance,
///   distinguishing gmail vs corporate vs SSO providers helps
///   triage auth issues.
/// - It isn't itself uniquely identifying without the local part;
///   thousands of users typically share a domain.
///
/// Same caveats as [_redactName]: this is incidental-exposure
/// mitigation, not strong anonymisation. Determined correlation
/// across logs can still narrow identity.
String _redactEmail(String email) {
  final atIndex = email.indexOf('@');
  if (atIndex < 0) return _redactName(email);
  final local = email.substring(0, atIndex);
  final domain = email.substring(atIndex);
  // Split-map-join over '.'-separated local-part segments. An
  // empty segment (consecutive dots, leading dot, trailing dot)
  // maps to '' via [_redactName]'s empty-string branch, preserving
  // the structural shape of the local part.
  final maskedLocal = local.split('.').map(_redactName).join('.');
  return '$maskedLocal$domain';
}
