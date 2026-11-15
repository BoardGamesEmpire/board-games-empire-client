import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/mail/mail_patch.dart';

/// The names of the Mail form's controls (#807), in its one [FormGroup].
abstract final class MailControls {
  static const host = 'host';
  static const port = 'port';
  static const security = 'security';
  static const user = 'user';
  static const password = 'password';
  static const from = 'from';
}

/// The errors the Mail form's checks set (#807), beside reactive_forms'
/// [ValidationMessage.email] on a From that isn't an address.
abstract final class MailErrors {
  /// On a port that isn't a whole number in the server's range.
  static const port = 'port';

  /// On a host, user, password or From longer than the server takes.
  static const tooLong = 'tooLong';

  /// On an empty new password while one is saved.
  static const emptyPassword = 'emptyPassword';

  /// Set by the form, not a check: a change of mail server needs the
  /// password, as the server says too.
  static const passwordRequired = 'passwordRequired';
}

/// Digits only. `int.tryParse` alone also takes a sign and a `0x` prefix, so
/// "0x50" would pass and save port 80.
final RegExp _digits = RegExp(r'^[0-9]+$');

/// A control's value as a whole number once trimmed, or null.
int? mailWholeNumber(Object? value) {
  final text = value is String ? value.trim() : '';
  return _digits.hasMatch(text) ? int.tryParse(text) : null;
}

/// The message for [MailErrors.tooLong].
String mailTooLongMessage(ServerSettingsLocalizations l10n) =>
    l10n.mailFieldTooLong(SystemSettingsRemoteDataSource.maxMailSettingLength);

Map<String, dynamic>? validMailPort(AbstractControl<dynamic> control) {
  final port = mailWholeNumber(control.value);
  return port == null ||
          port < SystemSettingsRemoteDataSource.minPort ||
          port > SystemSettingsRemoteDataSource.maxPort
      ? <String, dynamic>{MailErrors.port: true}
      : null;
}

/// At most the server's length, counted as the server counts it, once
/// trimmed as the server trims it.
Map<String, dynamic>? mailWithinLength(AbstractControl<dynamic> control) {
  final value = control.value;
  final text = value is String ? value.trim() : '';
  return _tooLong(text);
}

/// An email address once trimmed, or nothing.
Map<String, dynamic>? validMailFrom(AbstractControl<dynamic> control) {
  final value = control.value;
  final text = value is String ? value.trim() : '';
  return text.isEmpty || EmailValidator.emailRegex.hasMatch(text)
      ? null
      : <String, dynamic>{ValidationMessage.email: true};
}

/// The password field's check, given what the save does with the password
/// ([edit]) and whether one is saved ([passwordSaved]).
///
/// Checked only while a new password is being entered. It isn't trimmed: a
/// password may start or end with a space.
Map<String, dynamic>? checkMailPassword(
  Object? value, {
  required PasswordEdit edit,
  required bool passwordSaved,
}) {
  if (edit != PasswordEdit.replace) return null;
  final text = value is String ? value : '';
  if (text.isEmpty) {
    return passwordSaved
        ? <String, dynamic>{MailErrors.emptyPassword: true}
        : null;
  }
  return _tooLong(text);
}

Map<String, dynamic>? _tooLong(String text) =>
    serverStringLength(text) >
        SystemSettingsRemoteDataSource.maxMailSettingLength
    ? <String, dynamic>{MailErrors.tooLong: true}
    : null;
