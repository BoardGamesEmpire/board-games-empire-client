import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/game/expansion_placement.dart';
import 'package:models/src/domain/game/game_collection_list_item.dart';
import 'package:models/src/domain/game/game_medium.dart';
import 'package:models/src/domain/game/game_search_filter.dart';
import 'package:models/src/domain/game/platform_type.dart';

part 'collection_filter.freezed.dart';

/// One way a [CollectionFilter] narrows a collection, which the filter can
/// flip to keep what it doesn't match (#715).
enum CollectionFacet {
  /// The game's content type is in [GameSearchFilter.contentTypes].
  contentType,

  /// The entry's platform type is in [GameSearchFilter.platformTypes].
  platformType,

  /// The entry's medium is in [CollectionFilter.mediums].
  medium,

  /// The publish year fits [GameSearchFilter.publishYear].
  publishYear,

  /// The game supports every player count in [GameSearchFilter.playerCount].
  playerCount,

  /// The whole play time fits [GameSearchFilter.playTime].
  playTime,

  /// The item is an expansion shown without its base game.
  missingBaseGame,
}

/// What a collection is narrowed to on the device (#715).
///
/// [filterCollection] applies it. An item is kept when it matches [query] and
/// every facet in [facetsInUse]; a facet in [excluded] keeps the items it
/// doesn't match instead. A facet not in use changes nothing, excluded or
/// not.
@freezed
abstract class CollectionFilter with _$CollectionFilter {
  const factory CollectionFilter({
    /// Words to find in the title or subtitle, by [matchesSearchTerms]: every
    /// term of the query in one or the other, ignoring case and the
    /// punctuation around each word. A query with no terms, blank or
    /// punctuation alone, matches everything, and the query is never
    /// flipped.
    @Default('') String query,

    /// The content types, platform types and ranges; [filterCollection] says
    /// how each is read.
    @Default(GameSearchFilter()) GameSearchFilter game,

    /// The entry's media.
    @Default(<GameMedium>{}) Set<GameMedium> mediums,

    /// Whether to keep only the expansions shown without their base game.
    @Default(false) bool missingBaseGame,

    /// The facets flipped to keep the items they don't match.
    @Default(<CollectionFacet>{}) Set<CollectionFacet> excluded,
  }) = _CollectionFilter;
  const CollectionFilter._();

  /// The facets that narrow: a non-empty set, a range with a bound that
  /// isn't reversed, or the missing-base switch on.
  Set<CollectionFacet> get facetsInUse {
    bool inUse(GameSearchRange range) => range.narrows && !range.isReversed;
    return {
      if (game.contentTypes.isNotEmpty) CollectionFacet.contentType,
      if (game.platformTypes.isNotEmpty) CollectionFacet.platformType,
      if (mediums.isNotEmpty) CollectionFacet.medium,
      if (inUse(game.publishYear)) CollectionFacet.publishYear,
      if (inUse(game.playerCount)) CollectionFacet.playerCount,
      if (inUse(game.playTime)) CollectionFacet.playTime,
      if (missingBaseGame) CollectionFacet.missingBaseGame,
    };
  }

  /// Whether anything narrows: a facet in use, or a query with a term in it
  /// (see [matchesSearchTerms]).
  bool get narrows => facetsInUse.isNotEmpty || _searchTerms(query).isNotEmpty;
}

/// The orders a collection can be shown in on the device (#715).
///
/// Every order but [title] reads one fact of each item. An item missing the
/// fact an order reads goes last, and items that tie keep the order they
/// came in.
enum CollectionSort {
  /// The order given: the repository's, title ignoring case, then entry id.
  title,

  /// The entry's `createdAt`, newest first.
  recentlyAdded,

  /// The minimum play time, or the maximum when there is no minimum,
  /// shortest first.
  playTime,

  /// The minimum player count, fewest first.
  minPlayers,

  /// The maximum player count, most first.
  maxPlayers,

  /// The entry's rating, highest first.
  rating,
}

/// The items of [items] that [filter] keeps, in input order (#715).
///
/// An item is kept when every term of [CollectionFilter.query] is found in
/// its title or its subtitle, by [matchesSearchTerms], and, for each facet
/// in [CollectionFilter.facetsInUse], the facet's match below is true, or
/// false when the facet is in [CollectionFilter.excluded]:
///
/// - [CollectionFacet.contentType]: its `contentType` is in the set.
/// - [CollectionFacet.platformType]: its `platformType` is in the set; a
///   null platform type is in no set, and [PlatformType.unknown] only in a
///   set that names it.
/// - [CollectionFacet.medium]: its entry's `medium` is in the set.
/// - The three ranges: the rule the cached game search applies (drift's
///   `GameRepositoryImpl`, after the server's `localFilterConditions`). A
///   comparison with a missing value is no match, and the range's
///   `includeUnknown` then keeps the item when the value the range reads is
///   unknown:
///   - [CollectionFacet.publishYear]: the year is within the bounds given;
///     unknown when there is no year.
///   - [CollectionFacet.playerCount]: the game supports every count from
///     the range's minimum to its maximum, a bound alone being one count,
///     so both its player counts must be known; unknown when either is
///     missing.
///   - [CollectionFacet.playTime]: the whole play time fits the bounds
///     given, a game with one play time taking that long at both ends;
///     unknown when both are missing.
/// - [CollectionFacet.missingBaseGame]: the item is an expansion shown
///   without its base game, by `placeExpansions`' rule over all of [items]
///   (see [_missingBaseGame]), so the filter picks out exactly the rows the
///   list marks.
///
/// Returns [items] itself when [filter] doesn't narrow, and a new list
/// otherwise.
List<GameCollectionListItem> filterCollection(
  List<GameCollectionListItem> items,
  CollectionFilter filter,
) {
  if (!filter.narrows) return items;

  final query = filter.query;
  final facets = filter.facetsInUse;
  final gameIds = facets.contains(CollectionFacet.missingBaseGame)
      ? {for (final item in items) item.gameId}
      : const <String>{};

  bool matches(GameCollectionListItem item, CollectionFacet facet) {
    final game = filter.game;
    return switch (facet) {
      CollectionFacet.contentType => game.contentTypes.contains(
        item.contentType,
      ),
      CollectionFacet.platformType => game.platformTypes.contains(
        item.platformType,
      ),
      CollectionFacet.medium => filter.mediums.contains(item.entry.medium),
      CollectionFacet.publishYear => _inPublishYear(item, game.publishYear),
      CollectionFacet.playerCount => _supportsPlayerCount(
        item,
        game.playerCount,
      ),
      CollectionFacet.playTime => _fitsPlayTime(item, game.playTime),
      CollectionFacet.missingBaseGame => _missingBaseGame(item, gameIds),
    };
  }

  bool keeps(GameCollectionListItem item) {
    if (!matchesSearchTerms(query, [item.title, item.subtitle])) return false;
    for (final facet in facets) {
      if (matches(item, facet) == filter.excluded.contains(facet)) {
        return false;
      }
    }
    return true;
  }

  return [
    for (final item in items)
      if (keeps(item)) item,
  ];
}

/// [items] in [sort]'s order (#715); see [CollectionSort] for each one.
///
/// Every sort is stable: items that tie keep their input order, so ties stay
/// in title order. Returns [items] itself for [CollectionSort.title], and a
/// new list otherwise; [items] is never changed.
List<GameCollectionListItem> sortCollection(
  List<GameCollectionListItem> items,
  CollectionSort sort,
) {
  final int Function(GameCollectionListItem, GameCollectionListItem) compare;
  switch (sort) {
    case CollectionSort.title:
      return items;
    case CollectionSort.recentlyAdded:
      compare = (a, b) => b.entry.createdAt.compareTo(a.entry.createdAt);
    case CollectionSort.playTime:
      compare = (a, b) => _missingLast(
        a.minPlayTime ?? a.maxPlayTime,
        b.minPlayTime ?? b.maxPlayTime,
      );
    case CollectionSort.minPlayers:
      compare = (a, b) => _missingLast(a.minPlayers, b.minPlayers);
    case CollectionSort.maxPlayers:
      compare = (a, b) =>
          _missingLast(a.maxPlayers, b.maxPlayers, descending: true);
    case CollectionSort.rating:
      compare = (a, b) =>
          _missingLast(a.entry.rating, b.entry.rating, descending: true);
  }

  // List.sort is not stable on longer lists, so ties fall back to the input
  // index.
  final order = [for (var i = 0; i < items.length; i++) i]
    ..sort((a, b) {
      final byKey = compare(items[a], items[b]);
      return byKey != 0 ? byKey : a.compareTo(b);
    });
  return [for (final i in order) items[i]];
}

/// Compares [a] and [b] ascending, or [descending], with a missing value
/// after every present one.
int _missingLast(int? a, int? b, {bool descending = false}) {
  if (a == null || b == null) {
    if (a == null && b == null) return 0;
    return a == null ? 1 : -1;
  }
  return descending ? b.compareTo(a) : a.compareTo(b);
}

/// Whitespace, which separates a query's terms.
final _whitespace = RegExp(r'\s+');

/// Punctuation at either end of a term.
final _edgePunctuation = RegExp(r'^\p{P}+|\p{P}+$', unicode: true);

/// The terms of [query] (#715): its words, split on whitespace, each with
/// the punctuation at either end stripped and in lower case, leaving out a
/// word that was punctuation alone.
List<String> _searchTerms(String query) => [
  for (final word in query.split(_whitespace))
    if (word.replaceAll(_edgePunctuation, '') case final term
        when term.isNotEmpty)
      term.toLowerCase(),
];

/// Whether every term of [query] is found in one of [fields], ignoring
/// case (#715, #516).
///
/// The query's terms are its words, split on whitespace, with the
/// punctuation at either end of each stripped; a word that is punctuation
/// alone is no term. Each term may be found in a different field, so
/// "catan sea" and "Catan: Seafarers" both find a game titled "Catan" with
/// the subtitle "Seafarers", the name its row shows. A null field holds
/// nothing. A query with no terms, blank or punctuation alone, matches
/// everything.
bool matchesSearchTerms(String query, Iterable<String?> fields) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return true;
  final haystacks = [
    for (final field in fields)
      if (field != null) field.toLowerCase(),
  ];
  return terms.every((term) => haystacks.any((field) => field.contains(term)));
}

/// [match], widened to the items [unknown] picks out when [range] keeps
/// unknown values: the cached search's `_orUnknown`.
bool _orUnknown(
  GameSearchRange range, {
  required bool match,
  required bool unknown,
}) => match || (range.includeUnknown && unknown);

/// Whether [item]'s publish year is within [range]'s bounds; a bound left
/// out leaves that side open. An item with no year is unknown.
bool _inPublishYear(GameCollectionListItem item, GameSearchRange range) {
  final year = item.publishYear;
  return _orUnknown(
    range,
    match:
        year != null &&
        (range.min == null || year >= range.min!) &&
        (range.max == null || year <= range.max!),
    unknown: year == null,
  );
}

/// Whether [item] supports every player count in [range]. A bound alone is
/// one count (#580), so `min: 5` means "supports 5". Both of the item's
/// counts must be known to match; an item missing either is unknown.
bool _supportsPlayerCount(GameCollectionListItem item, GameSearchRange range) {
  final lo = (range.min ?? range.max)!;
  final hi = (range.max ?? range.min)!;
  final (min, max) = (item.minPlayers, item.maxPlayers);
  return _orUnknown(
    range,
    match: min != null && max != null && min <= lo && max >= hi,
    unknown: min == null || max == null,
  );
}

/// Whether [item]'s whole play time, in minutes, fits [range]. An item with
/// one play time takes that long, so it stands in for the missing end, and
/// a bound left out doesn't narrow that side. An item with neither is
/// unknown.
bool _fitsPlayTime(GameCollectionListItem item, GameSearchRange range) {
  final (shortest, longest) = (item.minPlayTime, item.maxPlayTime);
  final start = shortest ?? longest;
  final end = longest ?? shortest;
  return _orUnknown(
    range,
    match:
        (range.min == null || (start != null && start >= range.min!)) &&
        (range.max == null || (end != null && end <= range.max!)),
    unknown: shortest == null && longest == null,
  );
}

/// Whether [item] is an expansion shown without its base game:
/// [lacksBaseGame], the mark `placeExpansions` gives an anchor when its
/// list is complete, over [gameIds], the game ids of the whole list.
bool _missingBaseGame(GameCollectionListItem item, Set<String> gameIds) {
  final type = item.contentType;
  final (:bases, :standalone) = countedBaseGameLinks(
    gameId: item.gameId,
    baseGames: item.baseGames,
    contentType: type,
  );
  return lacksBaseGame(
    bases: bases,
    standalone: standalone,
    contentType: type,
    gameIds: gameIds,
  );
}
