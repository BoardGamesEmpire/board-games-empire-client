import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:network_interface/network_interface.dart';

HouseholdInviteRefusedException _refused(int status, {InviteQuota? quota}) =>
    HouseholdInviteRefusedException(
      'refused',
      statusCode: status,
      quota: quota,
    );

void main() {
  final l10n = lookupHouseholdLocalizations(const Locale('en'));

  String message(HouseholdInviteAction action, Object error) =>
      inviteRefusalMessage(l10n, action, error);

  const offline = "Couldn't reach the server. Try again.";
  const unexpected = 'Something went wrong on the server. Try again later.';

  group('inviteRefusalMessage', () {
    test('a transient failure asks to try again', () {
      for (final action in HouseholdInviteAction.values) {
        expect(
          message(action, const HouseholdInviteTransientException('t')),
          offline,
          reason: action.name,
        );
      }
    });

    test('a permanent failure, or any other error, is unexpected', () {
      for (final action in HouseholdInviteAction.values) {
        expect(
          message(action, const HouseholdInvitePermanentException('p')),
          unexpected,
        );
        expect(message(action, StateError('boom')), unexpected);
      }
    });

    test('a 410 is an expired invite, on any action', () {
      for (final action in HouseholdInviteAction.values) {
        expect(message(action, _refused(410)), 'This invite has expired.');
      }
    });

    test('a 404 is an invite or household that is gone, on any answer', () {
      for (final action in HouseholdInviteAction.values) {
        if (action == HouseholdInviteAction.send) continue;
        expect(
          message(action, _refused(404)),
          'This invite or its household no longer exists.',
        );
      }
    });

    test('a 404 on send is the household, or the person picked', () {
      expect(
        message(HouseholdInviteAction.send, _refused(404)),
        'This household, or the person you picked, no longer exists.',
      );
    });

    test('a 402 on the member cap says the household is full', () {
      expect(
        message(
          HouseholdInviteAction.accept,
          _refused(
            402,
            quota: const InviteQuota(
              resource: 'household_member_count',
              scope: 'Household',
            ),
          ),
        ),
        'This household has no room for another member.',
      );
    });

    test('a 402 on the sender\'s daily invites says it is theirs', () {
      expect(
        message(
          HouseholdInviteAction.send,
          _refused(
            402,
            quota: const InviteQuota(
              resource: 'household_invite_daily_count',
              scope: 'User',
            ),
          ),
        ),
        "You've reached your daily invite limit. Try again tomorrow.",
      );
    });

    test('any other 402 names the household\'s daily limit', () {
      const household =
          'This household has reached its daily invite limit. Try again '
          'tomorrow.';
      expect(
        message(
          HouseholdInviteAction.send,
          _refused(
            402,
            quota: const InviteQuota(
              resource: 'household_invite_daily_count',
              scope: 'Household',
            ),
          ),
        ),
        household,
      );
      expect(message(HouseholdInviteAction.approve, _refused(402)), household);
    });

    test('send: 400, 403 and 409', () {
      expect(
        message(HouseholdInviteAction.send, _refused(400)),
        'Check the invite: give one email address or pick one person, and '
        'not yourself.',
      );
      expect(
        message(HouseholdInviteAction.send, _refused(403)),
        "This invite can't be sent. You may no longer be allowed to invite "
        "here, or this person doesn't accept invites from you.",
      );
      expect(
        message(HouseholdInviteAction.send, _refused(409)),
        "They're already a member, or already have an open invite.",
      );
    });

    test('accept or decline: 403 is not yours to answer', () {
      for (final action in [
        HouseholdInviteAction.accept,
        HouseholdInviteAction.decline,
      ]) {
        expect(
          message(action, _refused(403)),
          "This invite isn't yours to answer.",
        );
      }
    });

    test('accept: 409 names every state that refuses it', () {
      expect(
        message(HouseholdInviteAction.accept, _refused(409)),
        "This invite can't be accepted now. It may already be answered or "
        "still awaiting approval, or you're already a member.",
      );
    });

    test('decline, withdraw, revoke or approve: 409 is already settled', () {
      for (final action in [
        HouseholdInviteAction.decline,
        HouseholdInviteAction.withdraw,
        HouseholdInviteAction.revoke,
        HouseholdInviteAction.approve,
      ]) {
        expect(
          message(action, _refused(409)),
          'This invite was already settled. The list is up to date.',
        );
      }
    });

    test('withdraw, revoke or approve: 403 is a role that changed', () {
      for (final action in [
        HouseholdInviteAction.withdraw,
        HouseholdInviteAction.revoke,
        HouseholdInviteAction.approve,
      ]) {
        expect(
          message(action, _refused(403)),
          "You can't do this any more. Your role in the household may have "
          'changed.',
        );
      }
    });

    test('any other refused status is unexpected', () {
      expect(message(HouseholdInviteAction.accept, _refused(400)), unexpected);
      expect(message(HouseholdInviteAction.revoke, _refused(400)), unexpected);
    });
  });
}
