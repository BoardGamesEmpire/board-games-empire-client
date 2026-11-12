import 'package:equatable/equatable.dart';

/// How the server secures its connection to the mail server (#807).
enum SmtpSecurity {
  startTls,
  implicitTls,
  none,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know.
  static SmtpSecurity fromWire(String name) => switch (name) {
    'StartTls' => SmtpSecurity.startTls,
    'ImplicitTls' => SmtpSecurity.implicitTls,
    'None' => SmtpSecurity.none,
    _ => SmtpSecurity.unknown,
  };

  /// The backend's enum name. [unknown] has none, so it is never sent.
  String get wireName => switch (this) {
    SmtpSecurity.startTls => 'StartTls',
    SmtpSecurity.implicitTls => 'ImplicitTls',
    SmtpSecurity.none => 'None',
    SmtpSecurity.unknown => throw StateError(
      'SmtpSecurity.unknown has no wire name',
    ),
  };
}

/// When the server links a sign-in provider to an existing account (#807).
enum ProviderLinkingPolicy {
  signedIn,
  automaticWhenVerified,

  /// A name this client does not know. Never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know.
  static ProviderLinkingPolicy fromWire(String name) => switch (name) {
    'SignedIn' => ProviderLinkingPolicy.signedIn,
    'AutomaticWhenVerified' => ProviderLinkingPolicy.automaticWhenVerified,
    _ => ProviderLinkingPolicy.unknown,
  };

  /// The backend's enum name. [unknown] has none, so it is never sent.
  String get wireName => switch (this) {
    ProviderLinkingPolicy.signedIn => 'SignedIn',
    ProviderLinkingPolicy.automaticWhenVerified => 'AutomaticWhenVerified',
    ProviderLinkingPolicy.unknown => throw StateError(
      'ProviderLinkingPolicy.unknown has no wire name',
    ),
  };
}

/// The server's settings, as an admin reads them (#807).
///
/// The SMTP password is never returned; [smtpPasswordSet] says whether one is
/// stored.
final class SystemSettings extends Equatable {
  const SystemSettings({
    required this.id,
    required this.smtpHost,
    required this.smtpPort,
    required this.smtpSecurity,
    required this.smtpUser,
    required this.smtpPasswordSet,
    required this.mailFromAddress,
    required this.passwordResetLinkLifetimeMinutes,
    required this.allowPasswordResets,
    required this.providerLinkingPolicy,
  });

  final String id;
  final String? smtpHost;
  final int smtpPort;
  final SmtpSecurity smtpSecurity;
  final String? smtpUser;
  final bool smtpPasswordSet;
  final String? mailFromAddress;
  final int passwordResetLinkLifetimeMinutes;
  final bool allowPasswordResets;
  final ProviderLinkingPolicy providerLinkingPolicy;

  /// Whether the server has what it needs to send mail: a host and a From.
  bool get mailConfigured => smtpHost != null && mailFromAddress != null;

  @override
  List<Object?> get props => [
    id,
    smtpHost,
    smtpPort,
    smtpSecurity,
    smtpUser,
    smtpPasswordSet,
    mailFromAddress,
    passwordResetLinkLifetimeMinutes,
    allowPasswordResets,
    providerLinkingPolicy,
  ];
}
