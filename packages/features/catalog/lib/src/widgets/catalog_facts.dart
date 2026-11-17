import 'package:flutter/material.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

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
/// The quick look lists them, with the year in its header (#707).
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

/// A fact and the label the game page's list gives it.
typedef LabelledFact = ({String label, GameFact value});

/// How many players a game takes, without the word "players", which the
/// game page's label for the row already says; null when neither bound is
/// known.
GameFact? playersValue(GameCatalogLocalizations l10n, int? min, int? max) =>
    switch ((min, max)) {
      (null, null) => null,
      (final int min, final int max) when min == max => sameFact('$min'),
      (final int min, final int max) => (
        shown: l10n.catalogDetailPlayersRange('$min', '$max'),
        spoken: l10n.catalogDetailPlayersRangeSpoken('$min', '$max'),
      ),
      (final int min, null) => (
        shown: l10n.catalogDetailPlayersAtLeast('$min'),
        spoken: l10n.catalogDetailPlayersAtLeastSpoken('$min'),
      ),
      (null, final int max) => sameFact(l10n.catalogDetailPlayersUpTo('$max')),
    };

/// The rows of the game page's list of facts, in order: type, year, players,
/// play time and age. A row whose fact is not known is left out.
List<LabelledFact> detailFacts(
  GameCatalogLocalizations l10n,
  GameFiltersLocalizations filterL10n,
  Game game,
) {
  final type = contentTypeLabel(filterL10n, game.contentType);
  final year = game.publishYear;
  final players = playersValue(l10n, game.minPlayers, game.maxPlayers);
  final time = playTimeFact(filterL10n, game);
  final age = game.minAge;
  return [
    if (type != null)
      (label: l10n.catalogDetailFactType, value: sameFact(type)),
    if (year != null)
      (
        label: l10n.catalogDetailFactPublished,
        value: sameFact(yearText(filterL10n, year)),
      ),
    if (players != null) (label: l10n.catalogDetailFactPlayers, value: players),
    if (time != null) (label: l10n.catalogDetailFactPlayTime, value: time),
    if (age != null)
      (
        label: l10n.catalogDetailFactAge,
        value: (
          shown: l10n.catalogDetailAgeValue('$age'),
          spoken: l10n.catalogDetailAgeValueSpoken('$age'),
        ),
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

/// [facts], one to a row. Each row is one paragraph, the label then the
/// value, so a long one wraps within its row at large text, and a screen
/// reader reads it as one item: the label, then the value.
///
/// The space between the label and the value is fixed, not translated; a
/// screen reader reads it as the comma in `catalogDetailFactSpoken`.
class CatalogFactList extends StatelessWidget {
  const CatalogFactList(this.facts, {super.key});

  final List<LabelledFact> facts;

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: BgeTokens.of(context).spaceXs,
      children: [
        for (final fact in facts)
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: fact.label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const TextSpan(text: ' '),
                TextSpan(
                  text: fact.value.shown,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
            semanticsLabel: l10n.catalogDetailFactSpoken(
              fact.label,
              fact.value.spoken,
            ),
          ),
      ],
    );
  }
}
