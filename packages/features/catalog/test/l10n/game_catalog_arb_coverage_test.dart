import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_test_support/l10n_test_support.dart';

/// The #33 key-coverage check for the catalog feature's ARB files, with the
/// policy every other feature package uses (see l10n_test_support's README):
/// template descriptions and locale declarations are hard failures, unknown
/// keys are hard failures, partial coverage is allowed and reported.
void main() {
  group('game_catalog ARB coverage', () {
    late ArbCoverageReport report;

    setUpAll(() {
      report = analyzeArbDirectory('lib/l10n', templateFileName: 'intl_en.arb');
    });

    test('the template names every content type but unknown (#42)', () {
      // The label switch is exhaustive over ContentType, and these are the
      // other half of that pairing.
      expect(
        report.templateKeys,
        containsAll(<String>[
          'catalogContentTypeBaseGame',
          'catalogContentTypeExpansion',
          'catalogContentTypeStandaloneExpansion',
          'catalogContentTypeExpandedEdition',
          'catalogContentTypeAccessory',
          'catalogContentTypeBundle',
          'catalogContentTypeDlc',
          'catalogContentTypeMod',
          'catalogContentTypePort',
          'catalogContentTypeRemake',
          'catalogContentTypeRemaster',
        ]),
      );
    });

    test('every template key carries a translator description', () {
      expect(report.keysMissingDescription, isEmpty, reason: report.describe());
    });

    test('no non-template locale carries keys the template lacks', () {
      for (final locale in report.locales) {
        expect(locale.unknownKeys, isEmpty, reason: report.describe());
      }
    });

    test('declared @@locale values agree with their file names', () {
      for (final locale in report.locales) {
        expect(
          locale.declaredLocaleMatchesFileName,
          isTrue,
          reason: '${locale.fileName} declares ${locale.declaredLocale}',
        );
      }
    });

    test('partial coverage is surfaced, not failed (repo policy)', () {
      if (report.hasUntranslated) {
        // ignore: avoid_print
        print(report.describe());
      }
    });
  });
}
