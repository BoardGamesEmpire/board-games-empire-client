import 'package:equatable/equatable.dart';

import 'package:models/src/domain/common/reach.dart';
import 'package:models/src/domain/system_settings/system_settings.dart';

/// A change to a nullable setting: store a value, or clear the column (#807).
///
/// On a [SystemSettingsPatch], a null field leaves the column alone;
/// [SettingValue.set] stores a value and [SettingValue.clear] sends `null`.
sealed class SettingValue<T extends Object> extends Equatable {
  const SettingValue();

  /// Store [value].
  const factory SettingValue.set(T value) = SettingSet<T>;

  /// Clear the column: sent as `null`.
  const factory SettingValue.clear() = SettingClear<T>;
}

/// Store [value] in the column.
final class SettingSet<T extends Object> extends SettingValue<T> {
  const SettingSet(this.value);

  final T value;

  @override
  List<Object?> get props => [value];
}

/// Clear the column.
final class SettingClear<T extends Object> extends SettingValue<T> {
  const SettingClear();

  @override
  List<Object?> get props => const [];
}

/// The settings an admin changed (#807, #894). A null field is left as it is.
final class SystemSettingsPatch extends Equatable {
  const SystemSettingsPatch({
    this.smtpHost,
    this.smtpPort,
    this.smtpSecurity,
    this.smtpUser,
    this.smtpPassword,
    this.mailFromAddress,
    this.passwordResetLinkLifetimeMinutes,
    this.allowPasswordResets,
    this.providerLinkingPolicy,
    this.name,
    this.allowUserRegistration,
    this.allowUsernameChange,
    this.feedbackReportRetentionDays,
    this.feedbackReportServerRedactionEnabled,
    this.requireContributionApproval,
    this.contributionReclaimDays,
    this.auditLogRetentionDays,
    this.householdInviteePolicy,
    this.eventInviteePolicy,
  });

  final SettingValue<String>? smtpHost;
  final int? smtpPort;
  final SmtpSecurity? smtpSecurity;
  final SettingValue<String>? smtpUser;
  final SettingValue<String>? smtpPassword;
  final SettingValue<String>? mailFromAddress;
  final int? passwordResetLinkLifetimeMinutes;
  final bool? allowPasswordResets;
  final ProviderLinkingPolicy? providerLinkingPolicy;
  final String? name;
  final bool? allowUserRegistration;
  final bool? allowUsernameChange;
  final int? feedbackReportRetentionDays;
  final bool? feedbackReportServerRedactionEnabled;
  final bool? requireContributionApproval;
  final int? contributionReclaimDays;

  /// Null keeps audit entries' retention as it is; [SettingValue.clear] keeps
  /// them indefinitely.
  final SettingValue<int>? auditLogRetentionDays;
  final Reach? householdInviteePolicy;
  final Reach? eventInviteePolicy;

  /// Whether nothing is being changed.
  bool get isEmpty => props.every((field) => field == null);

  /// Whether the patch moves where mail is sent through: the host, the port
  /// or the connection security.
  bool get changesMailServer =>
      smtpHost != null || smtpPort != null || smtpSecurity != null;

  @override
  List<Object?> get props => [
    smtpHost,
    smtpPort,
    smtpSecurity,
    smtpUser,
    smtpPassword,
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
