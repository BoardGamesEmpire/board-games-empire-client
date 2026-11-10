import 'package:flutter/material.dart';
import 'package:game_filters/l10n/game_filters_localizations.dart';
import 'package:game_filters/src/collection_filter_flips.dart';
import 'package:game_filters/src/game_facts.dart';
import 'package:game_filters/src/game_filter_keys.dart';
import 'package:game_filters/src/game_filter_options.dart';
import 'package:game_filters/src/game_length_band.dart';
import 'package:game_filters/src/in_use_chips.dart';
import 'package:models/domain.dart';

/// The filters in use, as chips (#474). Tapping one, or its remove button,
/// clears it, and [onChanged] gets the filter without it.
///
/// The chips come in the sheet's order, for what [options] offers: one per
/// chosen content type, platform type and medium, then one per range that
/// names a bound, then one for the missing-base switch. A range that keeps
/// unknown values says so, as "1990–2000 or no year", since those games are
/// kept too; clearing a range clears whether it keeps them. With no filter
/// in use it is empty.
///
/// A flipped facet's chips each start with "Not", shown and spoken: "Not
/// Tabletop", "Not 2–4 players" (#715). Clearing a facet's last chip takes
/// its flip with it.
///
/// The caller places it, under the field the list is searched with.
///
/// ## Focus
///
/// [InUseChips]', which draws the chips (#715): a removed chip hands focus
/// to the chip that took its place in the order, else the one before it,
/// once the caller has rebuilt this with the filter the chip sent, and only
/// if focus is free then. With no chip left, [onEmptied] is called, once,
/// for the caller to put focus on a control of its own, such as its Filters
/// button. A removal's hand-off waits for the next change of [filter]
/// alone: one that is the filter the chip sent settles it, and any other
/// drops it.
///
/// Keep it in the tree while it shows no chip, so that a hand-off to
/// [onEmptied] has a widget to run from: it draws nothing then.
class GameFiltersInUse extends StatelessWidget {
  const GameFiltersInUse({
    required this.filter,
    required this.onChanged,
    this.options = const GameFilterOptions(),
    this.onEmptied,
    super.key,
  });

  final CollectionFilter filter;
  final ValueChanged<CollectionFilter> onChanged;
  final GameFilterOptions options;

  /// Called once when the last chip is removed, however the press arrived,
  /// if focus is free afterwards (see Focus, above).
  final VoidCallback? onEmptied;

  @override
  Widget build(BuildContext context) {
    final l10n = GameFiltersLocalizations.of(context);
    return InUseChips<CollectionFilter>(
      value: filter,
      chips: [
        for (final (:id, :label, :without) in _filtersInUse(filter, options))
          if (label(l10n) case (:final shown, :final spoken))
            (
              id: id,
              key: GameFilterKeys.inUse(id),
              label: shown,
              semanticsLabel: spoken,
              removeLabel: l10n.gameFiltersFilterRemove(spoken),
              without: without,
            ),
      ],
      onRemove: (chip) => onChanged(chip.without),
      onEmptied: onEmptied,
    );
  }
}

/// How many filters [filter] has in use under [options]: one per chip
/// [GameFiltersInUse] shows with the same options, so the Filters button
/// counts exactly the chips under the field.
int gameFiltersInUseCount(
  CollectionFilter filter, {
  GameFilterOptions options = const GameFilterOptions(),
}) => _filtersInUse(filter, options).length;

/// One filter in use: its chip's `id`, how the chip names it, and the
/// filter once it is cleared.
typedef _InUse = ({
  String id,
  GameFact Function(GameFiltersLocalizations l10n) label,
  CollectionFilter without,
});

/// Every filter in use that [options] offers, in the sheet's order: one per
/// chosen content type, platform type and medium, one per range that names
/// a bound, and one for the missing-base switch.
///
/// Built without the labels, which only the chips read, so the count and
/// the chips come from this one list.
List<_InUse> _filtersInUse(
  CollectionFilter filter,
  GameFilterOptions options,
) {
  final game = filter.game;
  final GameSearchFilter(
    :contentTypes,
    :platformTypes,
    :publishYear,
    :playerCount,
    :playTime,
  ) = game;
  final excluded = filter.excluded;
  CollectionFilter without(CollectionFilter cleared) =>
      withoutIdleFlips(cleared);
  CollectionFilter withoutGame(GameSearchFilter game) =>
      without(filter.copyWith(game: game));
  const cleared = GameSearchRange();

  /// [label], said with "Not" while [facet] is flipped.
  GameFact Function(GameFiltersLocalizations) flippable(
    CollectionFacet facet,
    GameFact Function(GameFiltersLocalizations l10n) label,
  ) => !excluded.contains(facet)
      ? label
      : (l10n) {
          final (:shown, :spoken) = label(l10n);
          return (
            shown: l10n.gameFiltersInUseExcluded(shown),
            spoken: l10n.gameFiltersInUseExcluded(spoken),
          );
        };

  /// A range's [label], widened with [withUnknown] while it keeps unknown
  /// values.
  GameFact Function(GameFiltersLocalizations) range(
    CollectionFacet facet,
    GameSearchRange range,
    GameFact? Function(GameFiltersLocalizations l10n) label,
    String Function(GameFiltersLocalizations l10n, String range) withUnknown,
  ) => flippable(facet, (l10n) {
    // Only a range that names a bound is listed, and so has a label.
    final fact = label(l10n)!;
    if (!range.includeUnknown) return fact;
    return (
      shown: withUnknown(l10n, fact.shown),
      spoken: withUnknown(l10n, fact.spoken),
    );
  });

  return [
    for (final type in options.contentTypes)
      if (contentTypes.contains(type))
        (
          id: 'content_${type.name}',
          label: flippable(
            CollectionFacet.contentType,
            (l10n) => sameFact(contentTypeLabel(l10n, type)!),
          ),
          without: withoutGame(
            game.copyWith(contentTypes: {...contentTypes}..remove(type)),
          ),
        ),
    for (final type in options.platformTypes)
      if (platformTypes.contains(type))
        (
          id: 'platform_${type.name}',
          label: flippable(
            CollectionFacet.platformType,
            (l10n) => sameFact(platformTypeLabel(l10n, type)!),
          ),
          without: withoutGame(
            game.copyWith(platformTypes: {...platformTypes}..remove(type)),
          ),
        ),
    if (options.medium)
      for (final medium in GameMedium.values)
        if (filter.mediums.contains(medium))
          (
            id: 'medium_${medium.name}',
            label: flippable(
              CollectionFacet.medium,
              (l10n) => sameFact(mediumLabel(l10n, medium)),
            ),
            without: without(
              filter.copyWith(mediums: {...filter.mediums}..remove(medium)),
            ),
          ),
    if (publishYear.narrows)
      (
        id: 'year',
        label: range(
          CollectionFacet.publishYear,
          publishYear,
          (l10n) => _yearFact(l10n, publishYear),
          (l10n, range) => l10n.gameFiltersOrNoYear(range),
        ),
        without: withoutGame(game.copyWith(publishYear: cleared)),
      ),
    if (playerCount.narrows)
      (
        id: 'players',
        label: range(
          CollectionFacet.playerCount,
          playerCount,
          // A bound alone is one count (#580).
          (l10n) => playersFact(
            l10n,
            playerCount.min ?? playerCount.max,
            playerCount.max ?? playerCount.min,
          ),
          (l10n, range) => l10n.gameFiltersOrNoPlayerCount(range),
        ),
        without: withoutGame(game.copyWith(playerCount: cleared)),
      ),
    if (playTime.narrows)
      (
        id: 'time',
        label: range(
          CollectionFacet.playTime,
          playTime,
          (l10n) => _playTimeFact(l10n, playTime),
          (l10n, range) => l10n.gameFiltersOrNoPlayTime(range),
        ),
        without: withoutGame(game.copyWith(playTime: cleared)),
      ),
    if (options.missingBaseGame && filter.missingBaseGame)
      (
        id: 'missing_base_game',
        // Its own string flipped: "Not" can't be put before a fragment
        // that starts a sentence.
        label: excluded.contains(CollectionFacet.missingBaseGame)
            ? (l10n) => sameFact(l10n.gameFiltersMissingBaseGameExcluded)
            : (l10n) => sameFact(l10n.gameFiltersMissingBaseGameInUse),
        without: without(filter.copyWith(missingBaseGame: false)),
      ),
  ];
}

/// A publish-year range in use, or null when it names no year.
GameFact? _yearFact(GameFiltersLocalizations l10n, GameSearchRange range) {
  String year(int year) => yearText(l10n, year);
  return switch ((range.min, range.max)) {
    (final int min, final int max) when min == max => sameFact(year(min)),
    (final int min, final int max) => (
      shown: l10n.gameFiltersYearRange(year(min), year(max)),
      spoken: l10n.gameFiltersYearRangeSpoken(year(min), year(max)),
    ),
    (final int min, null) => sameFact(l10n.gameFiltersFromYear(year(min))),
    (null, final int max) => sameFact(l10n.gameFiltersUpToYear(year(max))),
    (null, null) => null,
  };
}

/// A play-time range in use, by its band's name where it is one, or null
/// when it names no time.
GameFact? _playTimeFact(GameFiltersLocalizations l10n, GameSearchRange range) =>
    switch (GameLengthBand.matching(range)) {
      final band? => sameFact(bandName(l10n, band)),
      null => playTimeRangeFact(l10n, range.min, range.max),
    };
