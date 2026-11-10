import 'package:game_filters/l10n/game_filters_localizations.dart';
import 'package:game_filters/src/game_length_band.dart';
import 'package:models/domain.dart';

/// One fact about a game, as it is shown and as a screen reader says it.
///
/// The filters name what they narrow by with these, and the catalog lists a
/// game's facts with the same labels, so a filter reads as the fact it
/// matches.
typedef GameFact = ({String shown, String spoken});

/// A fact that reads the same both ways.
GameFact sameFact(String text) => (shown: text, spoken: text);

/// The label of [type], or null for one this client does not know.
String? contentTypeLabel(GameFiltersLocalizations l10n, ContentType type) =>
    switch (type) {
      ContentType.baseGame => l10n.gameFiltersContentTypeBaseGame,
      ContentType.expansion => l10n.gameFiltersContentTypeExpansion,
      ContentType.standaloneExpansion =>
        l10n.gameFiltersContentTypeStandaloneExpansion,
      ContentType.expandedEdition => l10n.gameFiltersContentTypeExpandedEdition,
      ContentType.accessory => l10n.gameFiltersContentTypeAccessory,
      ContentType.bundle => l10n.gameFiltersContentTypeBundle,
      ContentType.dlc => l10n.gameFiltersContentTypeDlc,
      ContentType.mod => l10n.gameFiltersContentTypeMod,
      ContentType.port => l10n.gameFiltersContentTypePort,
      ContentType.remake => l10n.gameFiltersContentTypeRemake,
      ContentType.remaster => l10n.gameFiltersContentTypeRemaster,
      ContentType.unknown => null,
    };

/// The label of [type], or null for one this client does not know (#474).
String? platformTypeLabel(GameFiltersLocalizations l10n, PlatformType type) =>
    switch (type) {
      PlatformType.tabletop => l10n.gameFiltersPlatformTypeTabletop,
      PlatformType.console => l10n.gameFiltersPlatformTypeConsole,
      PlatformType.portable => l10n.gameFiltersPlatformTypePortable,
      PlatformType.pc => l10n.gameFiltersPlatformTypePc,
      PlatformType.mobile => l10n.gameFiltersPlatformTypeMobile,
      PlatformType.arcade => l10n.gameFiltersPlatformTypeArcade,
      PlatformType.other => l10n.gameFiltersPlatformTypeOther,
      PlatformType.unknown => null,
    };

/// How many players a game takes, or null when neither bound is known.
GameFact? playersFact(GameFiltersLocalizations l10n, int? min, int? max) =>
    switch ((min, max)) {
      (null, null) => null,
      (final int min, final int max) when min == max => sameFact(
        l10n.gameFiltersPlayerCount(min),
      ),
      (final int min, final int max) => (
        shown: l10n.gameFiltersPlayerRange('$min', '$max'),
        spoken: l10n.gameFiltersPlayerRangeSpoken('$min', '$max'),
      ),
      (final int min, null) => (
        shown: l10n.gameFiltersPlayersAtLeast('$min'),
        spoken: l10n.gameFiltersPlayersAtLeastSpoken('$min'),
      ),
      (null, final int max) => sameFact(l10n.gameFiltersPlayersUpTo('$max')),
    };

/// One play time, in minutes, as shown and as spoken (#579).
///
/// Under an hour it reads in minutes. From an hour on it reads in hours,
/// keeping any minutes left over, and never in days: 90 reads "1 hr 30 min",
/// and 90,000 "1,500 hr". A screen reader gets the words.
GameFact durationFact(GameFiltersLocalizations l10n, int minutes) {
  if (minutes < 60) {
    return (
      shown: l10n.gameFiltersMinutesShort(minutes),
      spoken: l10n.gameFiltersMinutes(minutes),
    );
  }
  final (hours, rest) = (minutes ~/ 60, minutes % 60);
  if (rest == 0) {
    return (
      shown: l10n.gameFiltersHoursShort(hours),
      spoken: l10n.gameFiltersHours(hours),
    );
  }
  return (
    shown: l10n.gameFiltersHoursMinutesShort(hours, rest),
    spoken: l10n.gameFiltersHoursMinutes(
      l10n.gameFiltersHours(hours),
      l10n.gameFiltersMinutes(rest),
    ),
  );
}

/// A play-time range, one unit where both ends share it (#579).
///
/// Both ends under an hour share minutes ("30–45 min"), and both whole hours
/// share hours ("1–2 hr"). Otherwise each end reads as [durationFact] does
/// ("45 min–1 hr 30 min").
GameFact durationRangeFact(GameFiltersLocalizations l10n, int min, int max) {
  if (min < 60 && max < 60) {
    return (
      shown: l10n.gameFiltersMinutesRangeShort(min, max),
      spoken: l10n.gameFiltersMinutesRange(min, max),
    );
  }
  if (min >= 60 && max >= 60 && min % 60 == 0 && max % 60 == 0) {
    return (
      shown: l10n.gameFiltersHoursRangeShort(min ~/ 60, max ~/ 60),
      spoken: l10n.gameFiltersHoursRange(min ~/ 60, max ~/ 60),
    );
  }
  final (from, to) = (durationFact(l10n, min), durationFact(l10n, max));
  return (
    shown: l10n.gameFiltersDurationRangeShort(from.shown, to.shown),
    spoken: l10n.gameFiltersDurationRange(from.spoken, to.spoken),
  );
}

/// A play time from [min] to [max] minutes, either of which may be left out,
/// or null with neither (#579): a game's play time, or a filter's.
///
/// Equal ends read as one time, and one end alone as the bound it is:
/// "Up to 2 hr", "30 min+".
GameFact? playTimeRangeFact(
  GameFiltersLocalizations l10n,
  int? min,
  int? max,
) => switch ((min, max)) {
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

GameFact _atLeast(GameFiltersLocalizations l10n, GameFact duration) => (
  shown: l10n.gameFiltersPlayTimeAtLeastShort(duration.shown),
  spoken: l10n.gameFiltersPlayTimeAtLeast(duration.spoken),
);

GameFact _upTo(GameFiltersLocalizations l10n, GameFact duration) => (
  shown: l10n.gameFiltersPlayTimeUpTo(duration.shown),
  spoken: l10n.gameFiltersPlayTimeUpTo(duration.spoken),
);

/// The name of [band], as the play-time filter offers it (#580).
String bandName(GameFiltersLocalizations l10n, GameLengthBand band) =>
    switch (band) {
      GameLengthBand.filler => l10n.gameFiltersBandFiller,
      GameLengthBand.quick => l10n.gameFiltersBandQuick,
      GameLengthBand.short => l10n.gameFiltersBandShort,
      GameLengthBand.medium => l10n.gameFiltersBandMedium,
      GameLengthBand.long => l10n.gameFiltersBandLong,
      GameLengthBand.epic => l10n.gameFiltersBandEpic,
      GameLengthBand.marathon => l10n.gameFiltersBandMarathon,
    };

/// A publish year; one before the common era reads "3000 BCE" (#565).
String yearText(GameFiltersLocalizations l10n, int year) =>
    year < 0 ? l10n.gameFiltersYearBce('${-year}') : '$year';
