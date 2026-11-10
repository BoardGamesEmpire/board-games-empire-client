import 'dart:convert';

import 'package:models/domain.dart';

/// The JSON a `games.base_games_json` column holds for [links] (#711).
String encodeExpansionLinks(List<ExpansionLink> links) =>
    jsonEncode([for (final link in links) link.toJson()]);

/// The links [json] holds; a malformed value reads as none, as a malformed
/// name list does.
///
/// The list literal builds every element, casts included, before `return`
/// leaves the `try`, so a corrupt element is caught here and not later, in
/// the caller's mapping code.
List<ExpansionLink> decodeExpansionLinks(String json) {
  try {
    return [
      for (final item in jsonDecode(json) as List)
        ExpansionLink.fromJson(item as Map<String, dynamic>),
    ];
  } on Object catch (_) {
    return [];
  }
}
