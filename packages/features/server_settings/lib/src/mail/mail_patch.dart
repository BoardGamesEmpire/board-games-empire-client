import 'package:models/domain.dart';

/// What a save does with the saved SMTP password (#807).
enum PasswordEdit {
  /// Leave the saved password as it is: it isn't sent.
  keep,

  /// Send the typed password in place of the saved one, or as the first.
  replace,

  /// Clear the saved password.
  remove,
}

/// The Mail group's values, as the form holds them.
///
/// The strings are as typed: [mailPatch] trims host, user and From, and never
/// the password. Built for a patch only from a valid form, so [port] and
/// [linkLifetimeMinutes] are whole numbers.
final class MailFormValues {
  const MailFormValues({
    required this.host,
    required this.port,
    required this.security,
    required this.user,
    required this.password,
    required this.passwordEdit,
    required this.from,
    required this.allowPasswordResets,
    required this.linkLifetimeMinutes,
  });

  final String host;
  final int port;

  /// Null while the server holds a security this app doesn't know and none
  /// was picked: left as it is.
  final SmtpSecurity? security;

  final String user;
  final String password;
  final PasswordEdit passwordEdit;
  final String from;
  final bool allowPasswordResets;
  final int linkLifetimeMinutes;
}

/// The settings [values] change, against [from] as the server last sent it.
///
/// A value equal to the stored one is left out. Host, user and From are
/// trimmed, as the server trims them, and an empty one clears the stored
/// value, or is left out when nothing is stored. The password goes only as
/// [MailFormValues.passwordEdit] says: typed and untrimmed, as `null` to
/// remove the saved one, or not at all. An empty typed password is never
/// sent: the server refuses one.
SystemSettingsPatch mailPatch(SystemSettings from, MailFormValues values) {
  final security = values.security;
  return SystemSettingsPatch(
    smtpHost: _text(from.smtpHost, values.host),
    smtpPort: values.port == from.smtpPort ? null : values.port,
    smtpSecurity:
        security == null ||
            security == SmtpSecurity.unknown ||
            security == from.smtpSecurity
        ? null
        : security,
    smtpUser: _text(from.smtpUser, values.user),
    smtpPassword: switch (values.passwordEdit) {
      PasswordEdit.keep => null,
      PasswordEdit.remove =>
        from.smtpPasswordSet ? const SettingValue.clear() : null,
      PasswordEdit.replace =>
        values.password.isEmpty ? null : SettingValue.set(values.password),
    },
    mailFromAddress: _text(from.mailFromAddress, values.from),
    passwordResetLinkLifetimeMinutes:
        values.linkLifetimeMinutes == from.passwordResetLinkLifetimeMinutes
        ? null
        : values.linkLifetimeMinutes,
    allowPasswordResets: values.allowPasswordResets == from.allowPasswordResets
        ? null
        : values.allowPasswordResets,
  );
}

SettingValue<String>? _text(String? stored, String typed) {
  final value = typed.trim();
  if (value.isEmpty) {
    return stored == null ? null : const SettingValue.clear();
  }
  return value == stored ? null : SettingValue.set(value);
}

/// Whether [patch] would keep the saved password for a different mail
/// server, which the server refuses (#807).
///
/// It refuses a change of host, port or security that keeps a saved
/// password, so the password never goes to a server it wasn't saved for. A
/// patch that clears the host is allowed: with no host, nothing is sent.
bool mailPasswordNeeded(
  SystemSettings from,
  SystemSettingsPatch patch,
  PasswordEdit edit,
) {
  if (!from.smtpPasswordSet ||
      edit != PasswordEdit.keep ||
      !patch.changesMailServer) {
    return false;
  }
  final host = switch (patch.smtpHost) {
    SettingSet<String>(:final value) => value,
    SettingClear<String>() => null,
    null => from.smtpHost,
  };
  return host != null;
}
