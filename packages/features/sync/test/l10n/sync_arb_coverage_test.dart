import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_test_support/l10n_test_support.dart';

/// The #33 key-coverage check for the sync feature's ARB files, under the
/// same policy as every other feature's (see l10n_test_support's README).
void main() {
  group('sync ARB coverage', () {
    late ArbCoverageReport report;

    setUpAll(() {
      report = analyzeArbDirectory('lib/l10n', templateFileName: 'intl_en.arb');
    });

    test('the template defines the stuck-changes key surface', () {
      // #190. The retry keeps its label while disabled, so both of its
      // strings are load-bearing accessible names.
      expect(
        report.templateKeys,
        containsAll(<String>[
          'syncStuckTitle',
          'syncStuckRetry',
          'syncStuckRetrying',
          'syncStuckDiscard',
          'syncStuckDiscardConfirm',
          'syncStuckNotice',
          'syncStuckNoticeAction',
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
  });
}
