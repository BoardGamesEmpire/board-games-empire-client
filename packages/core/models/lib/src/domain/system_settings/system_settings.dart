import 'package:equatable/equatable.dart';

import 'package:models/src/domain/common/reach.dart';

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

/// The server's settings, as an admin reads them (#807, #894).
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
    required this.name,
    required this.allowUserRegistration,
    required this.allowUsernameChange,
    required this.feedbackReportRetentionDays,
    required this.feedbackReportServerRedactionEnabled,
    required this.requireContributionApproval,
    required this.contributionReclaimDays,
    required this.auditLogRetentionDays,
    required this.householdInviteePolicy,
    required this.eventInviteePolicy,
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

  /// The server display name. Clients label the server with it when a user is
  /// choosing which server to add.
  final String name;

  /// Whether to allow new user registrations.
  final bool allowUserRegistration;

  /// Whether to allow users to change their usernames.
  final bool allowUsernameChange;

  /// How long to keep feedback reports, in days. Older reports are deleted
  /// automatically.
  final int feedbackReportRetentionDays;

  /// Whether the server redacts feedback reports before storing them. If
  /// false, it stores them as-is and relies on clients to redact.
  final bool feedbackReportServerRedactionEnabled;

  /// Whether a media contribution waits for staff approval before it is
  /// published.
  final bool requireContributionApproval;

  /// How long the contributor of a rejected media contribution has to reclaim
  /// it, in days.
  final int contributionReclaimDays;

  /// How long to keep audit log entries, in days. Null keeps them
  /// indefinitely.
  final int? auditLogRetentionDays;

  /// Who may be invited to a household. A user's own preference can narrow
  /// this, never widen it.
  final Reach householdInviteePolicy;

  /// Who may be placed on an event by id, at its creation or later. A user's
  /// own preference can narrow this, never widen it.
  final Reach eventInviteePolicy;

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
    name,
    allowUserRegistration,
    allowUsernameChange,
    feedbackReportRetentionDays,
    feedbackReportServerRedactionEnabled,
    requireContributionApproval,
    contributionReclaimDays,
    auditLogRetentionDays,
    householdInviteePolicy,
    eventInviteePolicy,
  ];
}
