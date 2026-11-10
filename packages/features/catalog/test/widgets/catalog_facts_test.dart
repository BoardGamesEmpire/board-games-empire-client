import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:game_filters/game_filters.dart';
import 'package:models/domain.dart';

/// The formatters' copy, from #474's table of play times (#579) and its
/// rule for years before the common era (#565).
void main() {
  final l10n = lookupGameCatalogLocalizations(const Locale('en'));
  final filterL10n = lookupGameFiltersLocalizations(const Locale('en'));

  Game timed({int? min, int? max}) => Game(
    id: 'g_timed',
    title: 'Timed',
    minPlayTime: min,
    maxPlayTime: max,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  group('playTimeFact', () {
    test('equal ends read as one time', () {
      expect(playTimeFact(filterL10n, timed(min: 90, max: 90)), (
        shown: '1 hr 30 min',
        spoken: '1 hour 30 minutes',
      ));
    });

    test('a range reads as one', () {
      expect(playTimeFact(filterL10n, timed(min: 60, max: 120)), (
        shown: '1–2 hr',
        spoken: '1 to 2 hours',
      ));
    });

    test('one end reads as the bound it is', () {
      expect(playTimeFact(filterL10n, timed(max: 120)), (
        shown: 'Up to 2 hr',
        spoken: 'Up to 2 hours',
      ));
      expect(playTimeFact(filterL10n, timed(min: 30)), (
        shown: '30 min+',
        spoken: '30 minutes or more',
      ));
    });

    test('no time is no fact', () {
      expect(playTimeFact(filterL10n, timed()), isNull);
    });
  });

  group('playFacts', () {
    test('are the players, the play time and the age, in that order', () {
      final base = timed(min: 30, max: 45);
      final game = base.copyWith(minPlayers: 1, maxPlayers: 5, minAge: 10);

      expect(playFacts(l10n, filterL10n, game), [
        (shown: '1–5 players', spoken: '1 to 5 players'),
        (shown: '30–45 min', spoken: '30 to 45 minutes'),
        (shown: 'Ages 10+', spoken: 'Ages 10 and up'),
      ]);
    });

    test('leave out what is not known', () {
      expect(playFacts(l10n, filterL10n, timed()), isEmpty);
      expect(playFacts(l10n, filterL10n, timed().copyWith(minAge: 8)), [
        (shown: 'Ages 8+', spoken: 'Ages 8 and up'),
      ]);
    });
  });

  group('yearText', () {
    test('a row shows a year before the common era as BCE', () {
      expect(rowFacts(filterL10n, year: -3000), [
        (shown: '3000 BCE', spoken: '3000 BCE'),
      ]);
    });
  });
}
