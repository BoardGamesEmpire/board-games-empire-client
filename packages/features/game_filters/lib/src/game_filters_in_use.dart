import 'package:flutter/material.dart';
import 'package:game_filters/l10n/game_filters_localizations.dart';
import 'package:game_filters/src/game_facts.dart';
import 'package:game_filters/src/game_filter_chip_label.dart';
import 'package:game_filters/src/game_filter_keys.dart';
import 'package:game_filters/src/game_filter_options.dart';
import 'package:game_filters/src/game_length_band.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The filters in use, as chips (#474). Tapping one, or its remove button,
/// clears it, and [onChanged] gets the filter without it.
///
/// The chips come in the sheet's order: one per chosen content type and
/// platform type that [options] offers, then one per range that names a
/// bound. A range that keeps unknown values says so, as "1990–2000 or no
/// year", since those games are kept too; clearing a range clears whether it
/// keeps them. With no filter in use it is empty.
///
/// The caller places it, under the field the list is searched with.
class GameFiltersInUse extends StatelessWidget {
  const GameFiltersInUse({
    required this.filter,
    required this.onChanged,
    this.options = const GameFilterOptions(),
    super.key,
  });

  final CollectionFilter filter;
  final ValueChanged<CollectionFilter> onChanged;
  final GameFilterOptions options;

  @override
  Widget build(BuildContext context) {
    final l10n = GameFiltersLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final inUse = _filtersInUse(l10n, filter, options);
    if (inUse.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: tokens.spaceSm,
      runSpacing: tokens.spaceSm,
      children: [
        for (final (:id, :label, :without) in inUse)
          InputChip(
            key: GameFilterKeys.inUse(id),
            label: GameFilterChipLabel(
              label.shown,
              semanticsLabel: label.spoken,
            ),
            onPressed: () => onChanged(without),
            onDeleted: () => onChanged(without),
            deleteButtonTooltipMessage: l10n.gameFiltersFilterRemove(
              label.spoken,
            ),
          ),
      ],
    );
  }
}

/// How many filters [filter] has in use: one per content type and platform
/// type chosen, and one per range that names a bound.
///
/// The Filters button shows it. [GameFiltersInUse] shows a chip for each,
/// since the sheet chooses no type its options leave out.
int gameFiltersInUseCount(CollectionFilter filter) {
  final game = filter.game;
  bool names(GameSearchRange range) => range.min != null || range.max != null;
  return game.contentTypes.length +
      game.platformTypes.length +
      [game.publishYear, game.playerCount, game.playTime].where(names).length;
}

/// One filter in use, as its chip shows it: `without` is the filter once it
/// is cleared.
typedef _InUse = ({String id, GameFact label, CollectionFilter without});

/// Every filter in use, in the sheet's order: one per chosen content type,
/// one per chosen platform type, and one per range that narrows.
List<_InUse> _filtersInUse(
  GameFiltersLocalizations l10n,
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
  CollectionFilter without(GameSearchFilter game) =>
      filter.copyWith(game: game);
  const cleared = GameSearchRange();
  GameFact? orUnknown(
    GameSearchRange range,
    GameFact? label,
    String Function(String range) withUnknown,
  ) => label == null || !range.includeUnknown
      ? label
      : (shown: withUnknown(label.shown), spoken: withUnknown(label.spoken));
  return [
    for (final type in options.contentTypes)
      if (contentTypes.contains(type))
        (
          id: 'content_${type.name}',
          label: sameFact(contentTypeLabel(l10n, type)!),
          without: without(
            game.copyWith(contentTypes: {...contentTypes}..remove(type)),
          ),
        ),
    for (final type in options.platformTypes)
      if (platformTypes.contains(type))
        (
          id: 'platform_${type.name}',
          label: sameFact(platformTypeLabel(l10n, type)!),
          without: without(
            game.copyWith(platformTypes: {...platformTypes}..remove(type)),
          ),
        ),
    if (orUnknown(
          publishYear,
          _yearFact(l10n, publishYear),
          l10n.gameFiltersOrNoYear,
        )
        case final label?)
      (
        id: 'year',
        label: label,
        without: without(game.copyWith(publishYear: cleared)),
      ),
    if (orUnknown(
          playerCount,
          // A bound alone is one count (#580).
          playersFact(
            l10n,
            playerCount.min ?? playerCount.max,
            playerCount.max ?? playerCount.min,
          ),
          l10n.gameFiltersOrNoPlayerCount,
        )
        case final label?)
      (
        id: 'players',
        label: label,
        without: without(game.copyWith(playerCount: cleared)),
      ),
    if (orUnknown(
          playTime,
          _playTimeFact(l10n, playTime),
          l10n.gameFiltersOrNoPlayTime,
        )
        case final label?)
      (
        id: 'time',
        label: label,
        without: without(game.copyWith(playTime: cleared)),
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
