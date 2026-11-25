import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';

/// The errors [apiKeyNameControl] sets beyond reactive_forms' own.
abstract final class ApiKeyNameErrors {
  /// The name is longer than [ApiKeyRemoteDataSource.maxNameLength].
  static const tooLong = 'apiKeyNameTooLong';

  /// The name holds a NUL character, which the server never takes in one.
  /// Pasted text can bring one in unseen.
  static const nul = 'apiKeyNameNul';
}

/// The control behind an API key's name field (#1028), starting at
/// [initial].
///
/// A name is required, and is 1 to [ApiKeyRemoteDataSource.maxNameLength]
/// characters once `trim()` has taken the spaces off its ends, as the remote
/// trims it before sending. Its length is Dart's `String.length`, which
/// counts UTF-16 units. That is stricter than the server's own count
/// (`serverStringLength`) and matches the sign-in library's check, so a name
/// that passes here passes both.
///
/// A name with nothing in it, or only spaces, has
/// `ValidationMessage.required`: reactive_forms trims a string before it
/// checks. One that is too long has [ApiKeyNameErrors.tooLong], and one with
/// a NUL character in it has [ApiKeyNameErrors.nul], as the server refuses
/// it.
///
/// Without [required], an empty name is valid: a key made outside the app
/// can have none, and an edit that leaves it unnamed is no edit of the name
/// (#1028).
FormControl<String> apiKeyNameControl({
  String? initial,
  bool required = true,
}) => FormControl<String>(
  value: initial,
  validators: apiKeyNameValidators(required: required),
);

/// The checks [apiKeyNameControl] makes, for a control whose key turns out
/// to have no name, or to have one, once it has loaded.
List<Validator<dynamic>> apiKeyNameValidators({bool required = true}) => [
  if (required) Validators.required,
  Validators.delegate(_notTooLong),
  Validators.delegate(_noNul),
];

Map<String, dynamic>? _notTooLong(AbstractControl<dynamic> control) {
  final value = control.value;
  final trimmed = value is String ? value.trim() : '';
  return trimmed.length > ApiKeyRemoteDataSource.maxNameLength
      ? <String, dynamic>{ApiKeyNameErrors.tooLong: true}
      : null;
}

Map<String, dynamic>? _noNul(AbstractControl<dynamic> control) {
  final value = control.value;
  return value is String && value.contains('\u{0}')
      ? <String, dynamic>{ApiKeyNameErrors.nul: true}
      : null;
}
