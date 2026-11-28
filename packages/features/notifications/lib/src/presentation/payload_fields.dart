// How the presenters read a notification's payload (#475). The payload is
// JSON the server sent, so every field is untrusted until it is read here.

/// [payload]'s [key] when it holds a string with more than whitespace in it,
/// else null.
String? nonBlankString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  return value is String && value.trim().isNotEmpty ? value : null;
}

/// Whether [payload]'s [key] holds something other than null or a string: a
/// payload the server wouldn't send, which is a plain row, not the wording for
/// a null.
bool isWrongType(Map<String, Object?> payload, String key) {
  final value = payload[key];
  return value != null && value is! String;
}
