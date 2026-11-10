import 'package:equatable/equatable.dart';

import 'package:models/src/domain/game/content_type.dart';
import 'package:models/src/domain/game/expansion_link.dart';

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
/// 3. Once the list is [complete], a linked item with `present` empty,
///    marked unless one of its base games is owned (below).
///
/// [ownedGameIds] are the game ids of the whole list [items] was narrowed
/// from, as a filter narrows a collection (#715); left out, they are
/// [items]' own. They decide a mark and move no game: where an item goes
/// follows what is shown, and an anchor of the third kind is marked only
/// when none of its base games is owned either, so an expansion whose base
/// game a filter hid is top level and unmarked. The mark is
/// [lacksBaseGame]'s answer over them, the rule the collection's
/// missing-base filter matches by.
///
/// Pass 2 places the other linked items. Each is nested when any of its
/// `present` base games is top level, and is top level, unmarked, when all
/// of them are nested: those base games are shown, only nested. While the
/// list is not [complete], an item with an `absent` base game is never put
/// at top level this way, as that base game may be on a later page and hold
/// it. So nesting is one level deep, and a chain of expansions alternates:
/// one nested under the base before it, the next top level, the one after
/// nested under that. A cycle no anchor leads into is top level, unmarked,
/// holding nothing, and so is an item that hangs from one: an expansion of a
/// cycle's member, an expansion of that, and so on. Links that loop are bad
/// data; this shows every game in them without picking a way to break the
/// loop.
///
/// Every item not held, a standalone one too, goes once into the expansions
/// of each of its `present` base games shown at top level, in input order.
///
/// While the list is not [complete], an item pass 2 leaves unplaced is
/// instead held, left out, when any of its base games is `absent`, or when
/// any of its `present` base games is held, and so on along a chain to a
/// fixpoint. This holds every linked item with `present` empty. Holding it
/// keeps rows from moving: a later page that brings the absent base game
/// nests the item under it rather than taking it from the top level. A
/// cycle with no held member stays top level. An item nested under a base
/// game shown at top level, and a standalone item, is never held; nothing
/// is held once the list is [complete].
///
/// The result lists the top-level items in input order, each once.
List<PlacedGame<T>> placeExpansions<T>(
  List<T> items, {
  required String Function(T item) gameIdOf,
  required List<ExpansionLink> Function(T item) baseGamesOf,
  required ContentType Function(T item) contentTypeOf,
  bool complete = true,
  Set<String>? ownedGameIds,
}) {
  final shown = {for (final item in items) gameIdOf(item)};
  final owned = ownedGameIds ?? shown;

  final entries = <_ItemLinks<T>>[];
  for (final item in items) {
    final type = contentTypeOf(item);
    final (:bases, :standalone) = countedBaseGameLinks(
      gameId: gameIdOf(item),
      baseGames: baseGamesOf(item),
      contentType: type,
    );
    final present = [
      for (final base in bases)
        if (shown.contains(base)) base,
    ];
    entries.add(
      _ItemLinks(
        item,
        linked: bases.isNotEmpty,
        present: present,
        someAbsent: present.length < bases.length,
        standalone: standalone,
        lacksBase: lacksBaseGame(
          bases: bases,
          standalone: standalone,
          contentType: type,
          gameIds: owned,
        ),
      ),
    );
  }

  final anchors = <String, bool>{}; // id -> missingBase
  for (final entry in entries) {
    if (!entry.linked ||
        entry.standalone ||
        (entry.present.isEmpty && complete)) {
      anchors[gameIdOf(entry.item)] = entry.lacksBase;
    }
  }

  // Decided in rounds out from the anchors, each from the one before's
  // answers, so the input's order changes nothing. Every undecided item is
  // linked and not standalone: anything else is an anchor.
  final top = {...anchors.keys};
  final nested = <String>{};
  var undecided = [
    for (final entry in entries)
      if (!anchors.containsKey(gameIdOf(entry.item))) entry,
  ];
  while (undecided.isNotEmpty) {
    final toTop = <String>[];
    final toNested = <String>[];
    final rest = <_ItemLinks<T>>[];
    for (final entry in undecided) {
      final id = gameIdOf(entry.item);
      if (entry.present.any(top.contains)) {
        toNested.add(id);
      } else if ((complete || !entry.someAbsent) &&
          entry.present.every(nested.contains)) {
        toTop.add(id);
      } else {
        rest.add(entry);
      }
    }
    if (toTop.isEmpty && toNested.isEmpty) break;
    top.addAll(toTop);
    nested.addAll(toNested);
    undecided = rest;
  }

  final held = <String>{};
  if (!complete) {
    for (final entry in undecided) {
      if (entry.someAbsent) held.add(gameIdOf(entry.item));
    }
    // Held-ness spreads along chains; the set only grows, so this ends.
    var grew = true;
    while (grew) {
      grew = false;
      for (final entry in undecided) {
        if (entry.present.any(held.contains)) {
          grew = held.add(gameIdOf(entry.item)) || grew;
        }
      }
    }
  }
  // What no round reaches and isn't held is a cycle or hangs from one: top
  // level, holding nothing.
  final cyclic = {
    for (final entry in undecided)
      if (!held.contains(gameIdOf(entry.item))) gameIdOf(entry.item),
  };

  final children = <String, List<T>>{};
  for (final entry in entries) {
    final id = gameIdOf(entry.item);
    if (held.contains(id) || cyclic.contains(id)) continue;
    for (final base in entry.present) {
      if (top.contains(base)) (children[base] ??= []).add(entry.item);
    }
  }

  return [
    for (final entry in entries)
      if (top.contains(gameIdOf(entry.item)) ||
          cyclic.contains(gameIdOf(entry.item)))
        PlacedGame(
          entry.item,
          expansions: children[gameIdOf(entry.item)] ?? const [],
          missingBase: anchors[gameIdOf(entry.item)] ?? false,
        ),
  ];
}

/// Which of a game's [baseGames] count, and whether it stands alone: the one
/// reading of its links that [placeExpansions] places by (#711) and
/// [lacksBaseGame] marks by.
///
/// `bases` are the ids of [baseGames] without a link to [gameId] itself,
/// each once, in the order first seen. The game is `standalone` when any
/// link `isStandalone` or [contentType] is [ContentType.standaloneExpansion].
///
/// Not part of the package's API: `domain.dart` hides it.
({List<String> bases, bool standalone}) countedBaseGameLinks({
  required String gameId,
  required List<ExpansionLink> baseGames,
  required ContentType contentType,
}) {
  // A key keeps its first-seen place when a later link updates its value.
  final standaloneByBase = <String, bool>{};
  for (final link in baseGames) {
    if (link.gameId == gameId) continue;
    standaloneByBase[link.gameId] =
        (standaloneByBase[link.gameId] ?? false) || link.isStandalone;
  }
  return (
    bases: [...standaloneByBase.keys],
    standalone:
        standaloneByBase.values.any((s) => s) ||
        contentType == ContentType.standaloneExpansion,
  );
}

/// Whether a game is an expansion without its base game among [gameIds]:
/// the mark [placeExpansions] gives an anchor (#711), and what the
/// collection's missing-base filter matches (#715), so the filter picks out
/// exactly the rows the list marks.
///
/// [bases] and [standalone] are [countedBaseGameLinks]' reading of the
/// game's links. The game lacks its base game:
///
/// - with no counted base game, exactly when it is a [ContentType.expansion]
///   or [ContentType.dlc];
/// - else, never when it is standalone;
/// - else, when none of its counted base games is in [gameIds].
///
/// Not part of the package's API: `domain.dart` hides it.
bool lacksBaseGame({
  required List<String> bases,
  required bool standalone,
  required ContentType contentType,
  required Set<String> gameIds,
}) {
  if (bases.isEmpty) {
    return contentType == ContentType.expansion ||
        contentType == ContentType.dlc;
  }
  if (standalone) return false;
  return !bases.any(gameIds.contains);
}

/// An item and what its links to base games say about where it goes.
class _ItemLinks<T> {
  const _ItemLinks(
    this.item, {
    required this.linked,
    required this.present,
    required this.someAbsent,
    required this.standalone,
    required this.lacksBase,
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

  /// Whether it is marked as missing its base game where it is an anchor:
  /// [lacksBaseGame] over the owned game ids.
  final bool lacksBase;
}
