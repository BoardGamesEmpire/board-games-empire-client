import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/widgets/catalog_facts.dart';
import 'package:models/domain.dart';

/// The formatters' copy, from #474's table of play times (#579) and its
/// rule for years before the common era (#565).
void main() {
  final l10n = lookupGameCatalogLocalizations(const Locale('en'));

  Game timed({int? min, int? max}) => Game(
    id: 'g_timed',
    title: 'Timed',
    minPlayTime: min,
    maxPlayTime: max,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  group('durationFact', () {
    test('under an hour reads in minutes', () {
      expect(durationFact(l10n, 45), (shown: '45 min', spoken: '45 minutes'));
      expect(durationFact(l10n, 1).spoken, '1 minute');
    });

    test('whole hours read in hours', () {
      expect(durationFact(l10n, 60), (shown: '1 hr', spoken: '1 hour'));
      expect(durationFact(l10n, 300), (shown: '5 hr', spoken: '5 hours'));
      expect(durationFact(l10n, 90000), (
        shown: '1,500 hr',
        spoken: '1,500 hours',
      ));
    });

    test('hours keep their remaining minutes', () {
      expect(durationFact(l10n, 90), (
        shown: '1 hr 30 min',
        spoken: '1 hour 30 minutes',
      ));
    });
  });

  group('durationRangeFact', () {
    test('a range under an hour shares minutes', () {
      expect(durationRangeFact(l10n, 30, 45), (
        shown: '30–45 min',
        spoken: '30 to 45 minutes',
      ));
    });

    test('a range of whole hours shares hours', () {
      expect(durationRangeFact(l10n, 60, 120), (
        shown: '1–2 hr',
        spoken: '1 to 2 hours',
      ));
    });

    test("a range that can't share a unit formats each end", () {
      expect(durationRangeFact(l10n, 45, 90), (
        shown: '45 min–1 hr 30 min',
        spoken: '45 minutes to 1 hour 30 minutes',
      ));
    });
  });

  group('playTimeFact', () {
    test('equal ends read as one time', () {
      expect(playTimeFact(l10n, timed(min: 90, max: 90)), (
        shown: '1 hr 30 min',
        spoken: '1 hour 30 minutes',
      ));
    });

    test('a range reads as one', () {
      expect(playTimeFact(l10n, timed(min: 60, max: 120)), (
        shown: '1–2 hr',
        spoken: '1 to 2 hours',
      ));
    });

    test('one end reads as the bound it is', () {
      expect(playTimeFact(l10n, timed(max: 120)), (
        shown: 'Up to 2 hr',
        spoken: 'Up to 2 hours',
      ));
      expect(playTimeFact(l10n, timed(min: 30)), (
        shown: '30 min+',
        spoken: '30 minutes or more',
      ));
    });

    test('no time is no fact', () {
      expect(playTimeFact(l10n, timed()), isNull);
    });
  });

  group('yearText', () {
    test('a year before the common era reads as BCE', () {
      expect(yearText(l10n, -3000), '3000 BCE');
    });

    test('a year of the common era reads as it is', () {
      expect(yearText(l10n, 1995), '1995');
    });

    test('a row shows a year before the common era as BCE', () {
      expect(rowFacts(l10n, year: -3000), [
        (shown: '3000 BCE', spoken: '3000 BCE'),
      ]);
    });
  });
}
