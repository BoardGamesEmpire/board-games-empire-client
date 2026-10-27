import 'package:flutter/material.dart';
import 'package:models/domain.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

/// One fact about a game, as it is shown and as a screen reader says it.
typedef CatalogFact = ({String shown, String spoken});

/// A fact that reads the same both ways.
CatalogFact sameFact(String text) => (shown: text, spoken: text);

/// The label of [type], or null for one this client does not know.
String? contentTypeLabel(GameCatalogLocalizations l10n, ContentType type) =>
    switch (type) {
      ContentType.baseGame => l10n.catalogContentTypeBaseGame,
      ContentType.expansion => l10n.catalogContentTypeExpansion,
      ContentType.standaloneExpansion =>
        l10n.catalogContentTypeStandaloneExpansion,
      ContentType.expandedEdition => l10n.catalogContentTypeExpandedEdition,
      ContentType.accessory => l10n.catalogContentTypeAccessory,
      ContentType.bundle => l10n.catalogContentTypeBundle,
      ContentType.dlc => l10n.catalogContentTypeDlc,
      ContentType.mod => l10n.catalogContentTypeMod,
      ContentType.port => l10n.catalogContentTypePort,
      ContentType.remake => l10n.catalogContentTypeRemake,
      ContentType.remaster => l10n.catalogContentTypeRemaster,
      ContentType.unknown => null,
    };

/// How many players a game takes, or null when neither bound is known.
CatalogFact? playersFact(GameCatalogLocalizations l10n, int? min, int? max) =>
    switch ((min, max)) {
      (null, null) => null,
      (final int min, final int max) when min == max => sameFact(
        l10n.catalogPlayerCount(min),
      ),
      (final int min, final int max) => (
        shown: l10n.catalogPlayerRange('$min', '$max'),
        spoken: l10n.catalogPlayerRangeSpoken('$min', '$max'),
      ),
      (final int min, null) => (
        shown: l10n.catalogPlayersAtLeast('$min'),
        spoken: l10n.catalogPlayersAtLeastSpoken('$min'),
      ),
      (null, final int max) => sameFact(l10n.catalogPlayersUpTo('$max')),
    };

/// How long a game takes to play, or null when that is not known.
///
/// Play time is minutes, and a single time is a range whose two ends are
/// equal (backend#869). One end alone reads as the bound it is, not as the
/// playing time.
CatalogFact? playTimeFact(GameCatalogLocalizations l10n, Game game) =>
    switch ((game.minPlayTime, game.maxPlayTime)) {
      (final int min, final int max) when min != max => (
        shown: l10n.catalogDetailPlayTimeRange('$min', '$max'),
        spoken: l10n.catalogDetailPlayTimeRangeSpoken('$min', '$max'),
      ),
      // The same minimum and maximum: one playing time.
      (final int minutes, final int _) => sameFact(
        l10n.catalogDetailPlayingTime(minutes),
      ),
      (final int min, null) => (
        shown: l10n.catalogDetailPlayTimeAtLeast('$min'),
        spoken: l10n.catalogDetailPlayTimeAtLeastSpoken(min),
      ),
      (null, final int max) => sameFact(l10n.catalogDetailPlayTimeUpTo(max)),
      (null, null) => null,
    };

/// The facts a row lists after the title: the year, the players, and the
/// content type when the game is not a base game, which most are.
List<CatalogFact> rowFacts(
  GameCatalogLocalizations l10n, {
  int? year,
  int? minPlayers,
  int? maxPlayers,
  ContentType contentType = ContentType.baseGame,
}) {
  final type = contentType == ContentType.baseGame
      ? null
      : contentTypeLabel(l10n, contentType);
  return [
    if (year != null) sameFact('$year'),
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

  final List<CatalogFact> facts;

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
