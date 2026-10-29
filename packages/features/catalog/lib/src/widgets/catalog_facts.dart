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

/// One play time, in minutes, as shown and as spoken (#579).
///
/// Under an hour it reads in minutes. From an hour on it reads in hours,
/// keeping any minutes left over, and never in days: 90 reads "1 hr 30 min",
/// and 90,000 "1,500 hr". A screen reader gets the words.
CatalogFact durationFact(GameCatalogLocalizations l10n, int minutes) {
  if (minutes < 60) {
    return (
      shown: l10n.catalogMinutesShort(minutes),
      spoken: l10n.catalogMinutes(minutes),
    );
  }
  final (hours, rest) = (minutes ~/ 60, minutes % 60);
  if (rest == 0) {
    return (
      shown: l10n.catalogHoursShort(hours),
      spoken: l10n.catalogHours(hours),
    );
  }
  return (
    shown: l10n.catalogHoursMinutesShort(hours, rest),
    spoken: l10n.catalogHoursMinutes(
      l10n.catalogHours(hours),
      l10n.catalogMinutes(rest),
    ),
  );
}

/// A play-time range, one unit where both ends share it (#579).
///
/// Both ends under an hour share minutes ("30–45 min"), and both whole hours
/// share hours ("1–2 hr"). Otherwise each end reads as [durationFact] does
/// ("45 min–1 hr 30 min").
CatalogFact durationRangeFact(GameCatalogLocalizations l10n, int min, int max) {
  if (min < 60 && max < 60) {
    return (
      shown: l10n.catalogMinutesRangeShort(min, max),
      spoken: l10n.catalogMinutesRange(min, max),
    );
  }
  if (min >= 60 && max >= 60 && min % 60 == 0 && max % 60 == 0) {
    return (
      shown: l10n.catalogHoursRangeShort(min ~/ 60, max ~/ 60),
      spoken: l10n.catalogHoursRange(min ~/ 60, max ~/ 60),
    );
  }
  final (from, to) = (durationFact(l10n, min), durationFact(l10n, max));
  return (
    shown: l10n.catalogDurationRangeShort(from.shown, to.shown),
    spoken: l10n.catalogDurationRange(from.spoken, to.spoken),
  );
}

/// How long a game takes to play, or null when that is not known.
///
/// Play time is minutes, and a single time is a range whose two ends are
/// equal (backend#869). One end alone reads as the bound it is, not as the
/// playing time.
CatalogFact? playTimeFact(GameCatalogLocalizations l10n, Game game) =>
    switch ((game.minPlayTime, game.maxPlayTime)) {
      (final int min, final int max) when min != max => durationRangeFact(
        l10n,
        min,
        max,
      ),
      // The same minimum and maximum: one playing time.
      (final int minutes, final int _) => durationFact(l10n, minutes),
      (final int min, null) => _atLeast(l10n, durationFact(l10n, min)),
      (null, final int max) => _upTo(l10n, durationFact(l10n, max)),
      (null, null) => null,
    };

CatalogFact _atLeast(GameCatalogLocalizations l10n, CatalogFact duration) => (
  shown: l10n.catalogPlayTimeAtLeastShort(duration.shown),
  spoken: l10n.catalogPlayTimeAtLeast(duration.spoken),
);

CatalogFact _upTo(GameCatalogLocalizations l10n, CatalogFact duration) => (
  shown: l10n.catalogPlayTimeUpTo(duration.shown),
  spoken: l10n.catalogPlayTimeUpTo(duration.spoken),
);

/// A publish year; one before the common era reads "3000 BCE" (#565).
String yearText(GameCatalogLocalizations l10n, int year) =>
    year < 0 ? l10n.catalogYearBce('${-year}') : '$year';

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
