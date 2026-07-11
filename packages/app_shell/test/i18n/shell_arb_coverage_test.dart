import 'dart:ui';

import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_test_support/l10n_test_support.dart';

/// The #33 key-coverage check for the shell's ARB files, per repo policy
/// (see l10n_test_support's README): template descriptions and locale
/// declarations are hard failures, unknown keys are hard failures,
/// partial coverage is allowed and reported.
///
/// `flutter test` runs with CWD at the package root, so `lib/l10n`
/// resolves to this package's ARB directory.
void main() {
  group('shell ARB coverage', () {
    late ArbCoverageReport report;

    setUpAll(() {
      report = analyzeArbDirectory('lib/l10n', templateFileName: 'intl_en.arb');
    });

    test('the template defines at least the shell key surface', () {
      expect(report.templateKeys, isNotEmpty);
      expect(report.templateKeys, contains('shellAppTitle'));
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
      // Deliberately no expect on untranslatedKeys — gen-l10n inherits
      // missing messages from the template, and blocking on complete key
      // sets would burden contributors adding a new language. Print for
      // visibility only.
      if (report.hasUntranslated) {
        // ignore: avoid_print
        print(report.describe());
      }
    });
  });

  group('locale policy (#33)', () {
    test('en is the first supported locale — Flutter\'s default '
        'resolution makes it the fallback with no custom callback', () {
      expect(ShellLocalizations.supportedLocales.first, const Locale('en'));
    });
  });
}
