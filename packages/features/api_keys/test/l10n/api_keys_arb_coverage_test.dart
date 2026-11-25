// Runs on the VM: it reads the ARB files through `dart:io`, which a browser
// doesn't have.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_test_support/l10n_test_support.dart';

/// The #33 key-coverage check for the API keys feature's ARB files, on the
/// same policy as every other feature package (see l10n_test_support's
/// README).
void main() {
  group('api_keys ARB coverage', () {
    late ArbCoverageReport report;

    setUpAll(() {
      report = analyzeArbDirectory('lib/l10n', templateFileName: 'intl_en.arb');
    });

    test('the template defines the title (#1028)', () {
      expect(report.templateKeys, contains('apiKeysTitle'));
    });

    test('every template key carries a translator description', () {
      expect(report.keysMissingDescription, isEmpty, reason: report.describe());
    });

    test('no non-template locale carries keys the template lacks', () {
      for (final locale in report.locales) {
        expect(locale.unknownKeys, isEmpty, reason: report.describe());
      }
    });
  });
}
