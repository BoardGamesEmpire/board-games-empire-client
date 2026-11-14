import 'package:characters/characters.dart';
import 'package:models/src/domain/user/person_name.dart';

/// The initials to show for a person named [name], or null where [name] is
/// null, empty or only whitespace (#349).
///
/// Two or more words give the first letter of the first word and of the last;
/// one word gives its first letter. A letter is a grapheme cluster, not a code
/// unit or a code point, so an accent written as a combining mark, an emoji
/// ZWJ sequence or a letter outside the Basic Multilingual Plane is never cut
/// in half.
///
/// Each letter is capitalised alone, and one whose capital is more than one
/// letter stays as written: on web, `toUpperCase` makes ß "SS" and ﬁ "FI".
///
/// Pair it with [personName], which decides which name to pass.
String? personInitials(String? name) {
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final words = trimmed.split(RegExp(r'\s+'));
  final first = _capital(words.first.characters.first);
  if (words.length == 1) return first;
  return '$first${_capital(words.last.characters.first)}';
}

/// [letter], one grapheme, capitalised where its capital is one grapheme too.
String _capital(String letter) {
  final upper = letter.toUpperCase();
  return upper.characters.length == 1 ? upper : letter;
}
