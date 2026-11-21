import 'dart:convert';

/// The strings a JSON list column holds, written with `jsonEncode`: a game's
/// name lists, and an event's or a date's rule lists (#1009). A malformed
/// value reads as `[]`, malformed JSON, a value that isn't a list and a
/// non-string element alike.
///
/// The trailing `.toList()` after `.cast<String>()` is load-bearing.
/// `cast<String>()` returns a lazy view that type-checks each element only
/// when it is read, so without it a corrupt element, such as an integer in a
/// list of strings, would not throw here. It would throw later, wherever the
/// caller first walks the list, outside this `try`. `.toList()` makes the
/// checked walk happen inside it, so the caller sees `[]` rather than an
/// unhandled [TypeError] in unrelated mapping code.
List<String> decodeStringList(String json) {
  try {
    return (jsonDecode(json) as List).cast<String>().toList();
  } on Object catch (_) {
    return [];
  }
}
