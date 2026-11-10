import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/l10n/game_filters_localizations.dart';
import 'package:game_filters/src/game_facts.dart';

/// The formatters' copy, from #474's table of play times (#579) and its
/// rule for years before the common era (#565).
void main() {
  final l10n = lookupGameFiltersLocalizations(const Locale('en'));

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

  group('yearText', () {
    test('a year before the common era reads as BCE', () {
      expect(yearText(l10n, -3000), '3000 BCE');
    });

    test('a year of the common era reads as it is', () {
      expect(yearText(l10n, 1995), '1995');
    });
  });
}
