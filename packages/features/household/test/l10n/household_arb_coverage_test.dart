// packages/features/household/test/l10n/household_arb_coverage_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_test_support/l10n_test_support.dart';

/// The #33 key-coverage check for the household feature's ARB files —
/// identical policy to the shell's and to feedback / server_onboarding
/// (see l10n_test_support's README): template descriptions and locale
/// declarations are hard failures, unknown keys are hard failures, partial
/// coverage is allowed and reported.
///
/// household was the last feature package without this check (#132), which
/// also left `l10n_test_support` an unused dev dependency here. Note what
/// this file is *not*: `l10n_test_support` analyzes ARB files on disk, it is
/// not a pump harness — the widget tests in this package assert against real
/// localized strings by pumping `HouseholdLocalizations.localizationsDelegates`
/// directly, which is the established pattern.
void main() {
  group('household ARB coverage', () {
    late ArbCoverageReport report;

    setUpAll(() {
      report = analyzeArbDirectory('lib/l10n', templateFileName: 'intl_en.arb');
    });

    test('the template defines at least the create-household key surface', () {
      expect(report.templateKeys, isNotEmpty);
      expect(report.templateKeys, contains('createHouseholdTitle'));
    });

    test('the template defines the keys the a11y surface depends on', () {
      // The in-flight button swaps its label rather than dropping it, so
      // both the submit label and the progress label are load-bearing
      // accessible names — see CreateHouseholdForm (#132).
      expect(
        report.templateKeys,
        containsAll(<String>[
          'createHouseholdSubmit',
          'createHouseholdInProgress',
        ]),
      );
    });

    test('the template defines the detail screen key surface', () {
      // #270. The role labels are listed one by one rather than as a
      // count: a role the switch can reach with no string is a compile
      // error only because the switch is exhaustive, and these keys are
      // the other half of that pairing.
      expect(
        report.templateKeys,
        containsAll(<String>[
          'householdDetailMembers',
          'householdDetailYourRole',
          'householdDetailRoleOwner',
          'householdDetailRoleAdmin',
          'householdDetailRoleMember',
          'householdDetailRoleGuest',
          'householdDetailRoleUnknown',
          'householdDetailNotFoundTitle',
          'householdDetailNotFoundBody',
          'householdDetailNotFoundAction',
          'householdDetailRefreshFailed',
          'householdDetailError',
          'householdDetailLoading',
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
