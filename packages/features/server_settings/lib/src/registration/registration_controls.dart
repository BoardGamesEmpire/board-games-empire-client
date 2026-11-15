import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:server_settings/src/whole_number.dart';

/// The errors the Registration and sign-in form's checks set (#894).
abstract final class RegistrationErrors {
  /// On a reset link lifetime that isn't a whole number of minutes in range.
  static const lifetime = 'lifetime';
}

/// A reset link lifetime's value as minutes in the server's range, or null.
int? resetLinkLifetime(Object? value) => wholeNumberIn(
  value,
  min: SystemSettingsRemoteDataSource.minLinkLifetimeMinutes,
  max: SystemSettingsRemoteDataSource.maxLinkLifetimeMinutes,
);

Map<String, dynamic>? validResetLinkLifetime(
  AbstractControl<dynamic> control,
) => resetLinkLifetime(control.value) == null
    ? <String, dynamic>{RegistrationErrors.lifetime: true}
    : null;
