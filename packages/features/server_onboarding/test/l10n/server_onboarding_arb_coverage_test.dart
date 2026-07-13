import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_test_support/l10n_test_support.dart';

/// The #33 key-coverage check for the server-onboarding feature's ARB
/// files — identical policy to the shell's and auth's: template
/// descriptions and locale declarations are hard failures, unknown keys
/// are hard failures, partial coverage is allowed and reported.
void main() {
  group('server_onboarding ARB coverage', () {
    late ArbCoverageReport report;

    setUpAll(() {
      report = analyzeArbDirectory('lib/l10n', templateFileName: 'intl_en.arb');
    });

    test('the template defines at least the onboarding key surface', () {
      expect(report.templateKeys, isNotEmpty);
      expect(report.templateKeys, contains('serverAddTitle'));
      expect(report.templateKeys, contains('serverAddErrorClientTooOld'));
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
