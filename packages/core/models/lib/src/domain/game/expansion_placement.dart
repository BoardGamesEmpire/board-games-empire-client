import 'package:equatable/equatable.dart';

import 'content_type.dart';
import 'expansion_link.dart';

/// One top-level item of a list, with the expansions shown under it (#711).
final class PlacedGame<T> extends Equatable {
  const PlacedGame(
    this.item, {
    this.expansions = const [],
    this.missingBase = false,
  });

  final T item;

  /// The expansions shown under [item], in the input's order.
  final List<T> expansions;

  /// True when [item] is an expansion shown without its base game.
  final bool missingBase;

  @override
  List<Object?> get props => [item, expansions, missingBase];
}

/// Places each of [items] at top level or under the base games [items] shows
/// (#711).
///
/// [items] must have unique game ids: two items with one id share one
/// expansions list.
///
/// For each item, `links` are its [baseGamesOf] without a link to itself and
/// de-duplicated by game id. `present` are the links whose base game is among
/// [items]; the others are `absent`. The item is `standalone` when any link
/// `isStandalone` or its content type is [ContentType.standaloneExpansion].
///
/// Pass 1 finds the anchors, items that are top level whatever the others do:
///
/// 1. An item with no links. It is marked as missing its base game exactly
///    when it is an [ContentType.expansion] or [ContentType.dlc]; any other
///    content type is an ordinary game.
/// 2. A standalone item, unmarked.
/// 3. Once the list is [complete], a linked item with `present` empty, marked.
///
/// Pass 2 nests the linked items. Its `parents` are the `present` links whose
/// base game is an anchor. The item goes once into each parent's expansions,
/// in input order. A linked, non-standalone item with `present` non-empty but
/// no parents (its `present` base games are themselves nested) is top level
/// and unmarked: those base games are shown, only nested.
///
/// While the list is not [complete], a linked, non-standalone item with no
/// parents is instead held, left out, when any of its base games is `absent`,
/// because that base game may be on a later page, or when any of its
/// `present` base games is held, and so on along a chain to a fixpoint. This
/// holds every linked item with `present` empty. Holding it keeps rows from
/// moving: a later page that brings the absent base game nests the item
/// under it rather than taking it from the top level. A cycle with no held
/// member stays top level. An item nested under an anchor, and a standalone
/// item, is never held; nothing is held once the list is [complete].
///
/// The result lists the top-level items in input order, each once.
List<PlacedGame<T>> placeExpansions<T>(
  List<T> items, {
  required String Function(T item) gameIdOf,
  required List<ExpansionLink> Function(T item) baseGamesOf,
  required ContentType Function(T item) contentTypeOf,
  bool complete = true,
}) {
  final shown = {for (final item in items) gameIdOf(item)};

  final entries = <_ItemLinks<T>>[];
  for (final item in items) {
    final id = gameIdOf(item);
    final standaloneByBase = <String, bool>{};
    for (final link in baseGamesOf(item)) {
      if (link.gameId == id) continue;
      standaloneByBase[link.gameId] =
          (standaloneByBase[link.gameId] ?? false) || link.isStandalone;
    }
    final present = [
      for (final base in standaloneByBase.keys)
        if (shown.contains(base)) base,
    ];
    final type = contentTypeOf(item);
    entries.add(
      _ItemLinks(
        item,
        linked: standaloneByBase.isNotEmpty,
        present: present,
        someAbsent: present.length < standaloneByBase.length,
        standalone:
            standaloneByBase.values.any((s) => s) ||
            type == ContentType.standaloneExpansion,
        expansionOrDlc:
            type == ContentType.expansion || type == ContentType.dlc,
      ),
    );
  }

  final anchors = <String, bool>{}; // id -> missingBase
  for (final entry in entries) {
    final id = gameIdOf(entry.item);
    if (!entry.linked) {
      anchors[id] = entry.expansionOrDlc;
    } else if (entry.standalone) {
      anchors[id] = false;
    } else if (entry.present.isEmpty && complete) {
      anchors[id] = true;
    }
  }

  final held = <String>{};
  if (!complete) {
    final unparented = [
      for (final entry in entries)
        if (entry.linked &&
            !entry.standalone &&
            !entry.present.any(anchors.containsKey))
          entry,
    ];
    for (final entry in unparented) {
      if (entry.someAbsent) held.add(gameIdOf(entry.item));
    }
    // Held-ness spreads along chains; the set only grows, so this ends.
    var grew = true;
    while (grew) {
      grew = false;
      for (final entry in unparented) {
        if (entry.present.any(held.contains)) {
          grew = held.add(gameIdOf(entry.item)) || grew;
        }
      }
    }
  }

  final children = <String, List<T>>{};
  final topLevel = <_ItemLinks<T>>[];
  for (final entry in entries) {
    final id = gameIdOf(entry.item);
    if (held.contains(id)) continue;
    final isAnchor = anchors.containsKey(id);
    if (entry.linked) {
      var nested = false;
      for (final base in entry.present) {
        if (anchors.containsKey(base)) {
          (children[base] ??= []).add(entry.item);
          nested = true;
        }
      }
      if (!isAnchor && !nested && entry.present.isNotEmpty) {
        topLevel.add(entry);
        continue;
      }
    }
    if (isAnchor) topLevel.add(entry);
  }

  return [
    for (final entry in topLevel)
      PlacedGame(
        entry.item,
        expansions: children[gameIdOf(entry.item)] ?? const [],
        missingBase: anchors[gameIdOf(entry.item)] ?? false,
      ),
  ];
}

/// An item and what its links to base games say about where it goes.
class _ItemLinks<T> {
  const _ItemLinks(
    this.item, {
    required this.linked,
    required this.present,
    required this.someAbsent,
    required this.standalone,
    required this.expansionOrDlc,
  });

  final T item;

  /// Whether the item links to any base game other than itself.
  final bool linked;

  /// The ids of its base games that are among the items.
  final List<String> present;

  /// Whether any of its base games is not among the items.
  final bool someAbsent;

  /// Whether it is shown at top level whatever its base games do.
  final bool standalone;

  /// Whether its content type is an expansion or DLC, marked when unlinked.
  final bool expansionOrDlc;
}
