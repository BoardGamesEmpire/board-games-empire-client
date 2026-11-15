import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/src/mail/mail_controls.dart';

/// The errors the Registration and sign-in form's checks set (#894).
abstract final class RegistrationErrors {
  /// On a reset link lifetime that isn't a whole number of minutes in range.
  static const lifetime = 'lifetime';
}

/// A reset link lifetime's value as minutes in the server's range, or null.
int? resetLinkLifetime(Object? value) {
  final minutes = mailWholeNumber(value);
  return minutes == null ||
          minutes < SystemSettingsRemoteDataSource.minLinkLifetimeMinutes ||
          minutes > SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes
      ? null
      : minutes;
}

Map<String, dynamic>? validResetLinkLifetime(
  AbstractControl<dynamic> control,
) => resetLinkLifetime(control.value) == null
    ? <String, dynamic>{RegistrationErrors.lifetime: true}
    : null;
