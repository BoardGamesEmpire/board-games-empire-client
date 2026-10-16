import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_test_support/l10n_test_support.dart';

/// The #33 key-coverage check for the DataGateway feature's ARB files, on the
/// same policy as every other feature package (see l10n_test_support's
/// README): template descriptions and locale declarations are hard failures,
/// unknown keys are hard failures, partial coverage is allowed and reported.
void main() {
  group('data_gateway ARB coverage', () {
    late ArbCoverageReport report;

    setUpAll(() {
      report = analyzeArbDirectory('lib/l10n', templateFileName: 'intl_en.arb');
    });

    test('the template defines the access key surface (#41)', () {
      // The two answers the gating gives a user: may not see DataGateways at
      // all, or may see them and not change them.
      expect(
        report.templateKeys,
        containsAll(<String>[
          'dataGatewayDeniedTitle',
          'dataGatewayDeniedBody',
          'dataGatewayChangeRefused',
        ]),
      );
    });

    test('the template defines the keys the a11y surface depends on', () {
      // The submit swaps its label rather than dropping it, the row menu is
      // named for its row, and a busy row's spinner has a label.
      expect(
        report.templateKeys,
        containsAll(<String>[
          'dataGatewayFormSubmitAdd',
          'dataGatewayFormSubmitEdit',
          'dataGatewayFormInProgress',
          'dataGatewayRowActions',
          'dataGatewayBusy',
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
