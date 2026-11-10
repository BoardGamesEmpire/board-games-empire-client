import 'package:flutter/material.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';

// The labels each fact is made of (`GameFact`, `contentTypeLabel`,
// `playersFact`, `playTimeRangeFact`, `yearText` and the rest) are
// `game_filters`', which names what a filter narrows by with the same ones
// (#715). These put them together for the catalog's rows and pages.

/// How long a game takes to play, or null when that is not known.
///
/// Play time is minutes, and a single time is a range whose two ends are
/// equal (backend#869). One end alone reads as the bound it is, not as the
/// playing time.
GameFact? playTimeFact(GameFiltersLocalizations l10n, Game game) =>
    playTimeRangeFact(l10n, game.minPlayTime, game.maxPlayTime);

/// Who a game is for and how long it takes: its players, its play time and
/// the youngest age it is for, each where it is known.
///
/// The detail page lists them after the content type and the year, and the
/// quick look on their own, with the year in its header (#707).
List<GameFact> playFacts(
  GameCatalogLocalizations l10n,
  GameFiltersLocalizations filterL10n,
  Game game,
) {
  final age = game.minAge;
  return [
    ?playersFact(filterL10n, game.minPlayers, game.maxPlayers),
    ?playTimeFact(filterL10n, game),
    if (age != null)
      (
        shown: l10n.catalogDetailMinAge('$age'),
        spoken: l10n.catalogDetailMinAgeSpoken('$age'),
      ),
  ];
}

/// The facts a row lists after the title: the year, the players, and the
/// content type when the game is not a base game, which most are.
List<GameFact> rowFacts(
  GameFiltersLocalizations l10n, {
  int? year,
  int? minPlayers,
  int? maxPlayers,
  ContentType contentType = ContentType.baseGame,
}) {
  final type = contentType == ContentType.baseGame
      ? null
      : contentTypeLabel(l10n, contentType);
  return [
    if (year != null) sameFact(yearText(l10n, year)),
    ?playersFact(l10n, minPlayers, maxPlayers),
    if (type != null) sameFact(type),
  ];
}

/// A game's name, with its subtitle when it has one.
String gameTitle(
  GameCatalogLocalizations l10n,
  String title,
  String? subtitle,
) => subtitle == null || subtitle.isEmpty
    ? title
    : l10n.catalogTitleWithSubtitle(title, subtitle);

/// [facts] on one line, joined differently for the eye and the ear: a
/// screen reader would read the visual separator's symbol out.
class CatalogFactsText extends StatelessWidget {
  const CatalogFactsText(this.facts, {super.key});

  final List<GameFact> facts;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    return Text(
      facts.map((f) => f.shown).join(l10n.catalogDetailSeparator),
      semanticsLabel: facts
          .map((f) => f.spoken)
          .join(l10n.catalogDetailSpokenSeparator),
    );
  }
}
