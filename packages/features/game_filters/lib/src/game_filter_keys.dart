import 'package:flutter/widgets.dart';
import 'package:game_filters/src/game_length_band.dart';
import 'package:models/domain.dart';

/// The keys on the filter sheet's controls, the Filters button and the
/// chips naming the filters in use, for a caller's tests to find them by.
///
/// The values carry the `catalog_search.` prefix: the game search's own
/// filter keys forward to these, and its tests find the widgets by them
/// (#715).
abstract final class GameFilterKeys {
  /// The button that opens the sheet: `GameFiltersButton`'s.
  static const Key button = Key('catalog_search.filters');

  /// The sheet's own scroll view.
  static const Key sheet = Key('catalog_search.filter_sheet');

  /// The sheet's Clear all button.
  static const Key clearAll = Key('catalog_search.filters_clear_all');

  /// The sheet's chip for [type].
  static Key contentType(ContentType type) =>
      Key('catalog_search.filter_${type.name}');

  /// The sheet's chip for [type].
  static Key platformType(PlatformType type) =>
      Key('catalog_search.platform_${type.name}');

  /// The sheet's chip for [medium] (#715).
  static Key medium(GameMedium medium) =>
      Key('catalog_search.medium_${medium.name}');

  /// The sheet's switch that keeps only the expansions shown without their
  /// base game (#715).
  static const Key missingBaseGame = Key('catalog_search.missing_base_game');

  /// The switch under [facet]'s section that leaves out what it matches
  /// instead of keeping it (#715).
  static Key exclude(CollectionFacet facet) =>
      Key('catalog_search.exclude_${facet.name}');

  /// The chip for one filter in use: `content_<name>`, `platform_<name>`,
  /// `medium_<name>`, `year`, `players`, `time` or `missing_base_game`.
  static Key inUse(String id) => Key('catalog_search.in_use_$id');

  /// A range's From field, or its To field when [from] is false. [range]
  /// is one of the three ranges: [CollectionFacet.publishYear],
  /// [CollectionFacet.playerCount] or [CollectionFacet.playTime].
  static Key rangeField(CollectionFacet range, {required bool from}) =>
      Key('catalog_search.${_rangeName(range)}_${from ? 'from' : 'to'}');

  /// The switch that keeps games with no value for [range], one of the three
  /// ranges.
  static Key includeUnknown(CollectionFacet range) =>
      Key('catalog_search.${_rangeName(range)}_unknown');

  /// The sheet's choice of [band] for the play time.
  static Key band(GameLengthBand band) =>
      Key('catalog_search.band_${band.name}');

  /// The name a range's keys carry, which its in-use chip's id is too.
  static String _rangeName(CollectionFacet range) => switch (range) {
    CollectionFacet.publishYear => 'year',
    CollectionFacet.playerCount => 'players',
    CollectionFacet.playTime => 'time',
    CollectionFacet.contentType ||
    CollectionFacet.platformType ||
    CollectionFacet.medium ||
    CollectionFacet.missingBaseGame => throw ArgumentError.value(
      range,
      'range',
      'is not a range',
    ),
  };
}
