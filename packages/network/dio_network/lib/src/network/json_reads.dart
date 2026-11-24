/// [raw] as a JSON object, or a [FormatException] naming [field].
///
/// It takes the value rather than a body and a key, so the same reader serves
/// a top-level field (`requireObject(body['event'], 'event')`) and a nested
/// one (`requireObject(platformGame['game'], 'platformGame.game')`). An absent
/// key and a null value both read as `"X" is Null`.
Map<String, dynamic> requireObject(Object? raw, String field) {
  if (raw is! Map<String, dynamic>) {
    throw FormatException('"$field" is ${raw.runtimeType}, expected an object');
  }
  return raw;
}

/// Parses an optional ISO-8601 timestamp: null stays null.
///
/// A value that is neither null nor a string throws a [TypeError], and a
/// string that isn't a timestamp throws a [FormatException]. The caller's
/// `parseRemote` files either as the server breaking the contract.
DateTime? dateOrNull(Object? value) =>
    value == null ? null : DateTime.parse(value as String);
