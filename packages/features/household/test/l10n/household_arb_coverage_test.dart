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

    test('the template defines the refresh-retry key surface', () {
      // #300. Both load-bearing accessible names: the retry button keeps
      // its label while disabled rather than becoming a bare spinner, and
      // the in-progress copy is what the banner's live region announces.
      // They are screen-agnostic on purpose — the list banner and the
      // detail banner run the same pass, so one wording serves both.
      expect(
        report.templateKeys,
        containsAll(<String>[
          'householdRefreshRetry',
          'householdRefreshInProgress',
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

    test('the template defines one message per invite refusal (#455)', () {
      expect(
        report.templateKeys,
        containsAll(<String>[
          'inviteErrorOffline',
          'inviteErrorUnexpected',
          'inviteErrorExpired',
          'inviteErrorGone',
          'inviteErrorHouseholdFull',
          'inviteErrorDailyLimitYou',
          'inviteErrorDailyLimitHousehold',
          'inviteSendErrorInvalid',
          'inviteSendErrorRefused',
          'inviteSendErrorConflict',
          'inviteSendErrorGone',
          'inviteAnswerErrorNotYours',
          'inviteAcceptErrorConflict',
          'inviteErrorAlreadySettled',
          'inviteErrorRoleChanged',
        ]),
      );
    });

    test('the template defines the household invite list surface (#455)', () {
      expect(
        report.templateKeys,
        containsAll(<String>[
          'householdInvitesTitle',
          'householdInvitesLoading',
          'householdInvitesFilterOpen',
          'householdInvitesFilterAwaiting',
          'householdInvitesEmpty',
          'householdInvitesEmptyAwaiting',
          'householdInvitesDenied',
          'householdInvitesFailed',
          'householdInvitesFailedBody',
          'householdInvitesRetry',
          'householdInvitesMore',
          'householdInvitesInvite',
          'householdInvitesDismiss',
          'householdInviteToAccount',
          'householdInviteFrom',
          'householdInviteExpires',
          'householdInviteStatusAwaiting',
          'householdInviteBusy',
          'householdInviteWithdraw',
          'householdInviteRevoke',
          'householdInviteApprove',
          'householdInviteTurnDown',
          'householdInviteRevokeConfirmTitle',
          'householdInviteRevokeConfirmBody',
          'householdInviteTurnDownConfirmTitle',
          'householdInviteTurnDownConfirmBody',
          'householdInviteCancel',
          'householdInviteDoneWithdraw',
          'householdInviteDoneRevoke',
          'householdInviteDoneApprove',
        ]),
      );
    });

    test('the template defines the send-invite form surface (#455)', () {
      expect(
        report.templateKeys,
        containsAll(<String>[
          'inviteSendTitle',
          'inviteSendByEmail',
          'inviteSendByPerson',
          'inviteSendEmailLabel',
          'inviteSendEmailRequired',
          'inviteSendEmailInvalid',
          'inviteSendSearchLabel',
          'inviteSendSearchHint',
          'inviteSendSearchEmpty',
          'inviteSendSearchFailed',
          'inviteSendPickRequired',
          'inviteSendNameLabel',
          'inviteSendNameTooLong',
          'inviteSendRoleLabel',
          'inviteSendMessageLabel',
          'inviteSendMessageTooLong',
          'inviteSendSubmit',
          'inviteSendSending',
          'inviteSendFailedTitle',
          'inviteSendDone',
        ]),
      );
    });

    test("the template defines the send-invite form's member surface "
        '(#569)', () {
      expect(
        report.templateKeys,
        containsAll(<String>[
          'inviteSendNeedsApprovalNote',
          'inviteSendDoneAwaitingApproval',
          'inviteSendNotAllowedGuest',
          'inviteSendNotAllowedOff',
          'inviteSendNotAllowedUnknown',
          'inviteSendNotAllowedUnrecognisedPolicy',
          'inviteSendNotAllowedUnrecognisedRole',
        ]),
      );
    });

    test('the template defines the invite inbox surface (#455)', () {
      expect(
        report.templateKeys,
        containsAll(<String>[
          'inviteInboxTitle',
          'inviteInboxLoading',
          'inviteInboxEmpty',
          'inviteInboxFailed',
          'inviteInboxUnknownHousehold',
          'inviteInboxAccept',
          'inviteInboxDecline',
          'inviteInboxDeclineConfirmTitle',
          'inviteInboxDeclineConfirmBody',
          'inviteInboxJoined',
          'inviteInboxOpenHousehold',
          'inviteInboxDeclined',
        ]),
      );
    });

    test('the template defines the sent invites surface (#487)', () {
      // With the two #487 strings drawn elsewhere: the expired line every
      // invite row shows, and the empty inbox's link to this screen.
      expect(
        report.templateKeys,
        containsAll(<String>[
          'sentInvitesTitle',
          'sentInvitesLoading',
          'sentInvitesFailed',
          'sentInvitesEmpty',
          'sentInvitesEmptyFiltered',
          'sentInvitesFilterLabel',
          'sentInvitesFilterOpenAndExpired',
          'inviteStatusPending',
          'inviteStatusExpired',
          'inviteStatusAccepted',
          'inviteStatusDeclined',
          'inviteStatusWithdrawn',
          'inviteStatusRevoked',
          'sentInviteFor',
          'sentInviteForAccount',
          'householdInviteExpired',
          'inviteInboxSentLink',
        ]),
      );
    });

    test("the template defines the household screen's invites entry "
        '(#455, #489)', () {
      expect(
        report.templateKeys,
        containsAll(<String>[
          'householdDetailInvites',
          'householdDetailInvitesAwaiting',
        ]),
      );
    });

    test('partial coverage is surfaced, not failed (repo policy)', () {
      if (report.hasUntranslated) {
        // ignore: avoid_print
        print(report.describe());
      }
    });
  });
}
