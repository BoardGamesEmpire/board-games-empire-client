/// Digits only. `int.tryParse` alone also takes a sign and a `0x` prefix, so
/// "0x50" would pass and save port 80.
final RegExp _digits = RegExp(r'^[0-9]+$');

/// A control's value as a whole number once trimmed, or null.
int? wholeNumber(Object? value) {
  final text = value is String ? value.trim() : '';
  return _digits.hasMatch(text) ? int.tryParse(text) : null;
}

/// A control's value as a whole number from [min] to [max], or null.
int? wholeNumberIn(Object? value, {required int min, required int max}) {
  final number = wholeNumber(value);
  return number == null || number < min || number > max ? null : number;
}
