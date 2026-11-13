import 'package:equatable/equatable.dart';

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

/// The settings an admin changed (#807). A null field is left as it is.
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
  ];
}
