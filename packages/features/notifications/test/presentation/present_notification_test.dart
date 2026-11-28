import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:notifications/l10n/notifications_localizations_en.dart';
import 'package:notifications/notifications.dart';

void main() {
  final l10n = NotificationsLocalizationsEn();

  UserNotification notification(String type, Map<String, Object?> payload) =>
      UserNotification(
        id: 'n1',
        type: type,
        payload: payload,
        read: false,
        createdAt: DateTime.utc(2026, 11, 27),
      );

  NotificationPresentation present(
    String type,
    Map<String, Object?> payload,
  ) => presentNotification(l10n, notification(type, payload));

  const household = <String, Object?>{
    'householdId': 'h1',
    'householdName': 'The Smiths',
  };

  final plain = NotificationPresentation(
    icon: Icons.notifications_none,
    title: l10n.notificationUnknownTitle,
  );

  group('HouseholdInviteReceived', () {
    const payload = {...household, 'inviteId': 'i1', 'inviterName': 'Ana'};

    test('names the inviter and the household, and opens the invites', () {
      final presentation = present('HouseholdInviteReceived', payload);

      expect(presentation.title, contains('Ana'));
      expect(presentation.title, contains('The Smiths'));
      expect(presentation.detail, isNull);
      expect(presentation.icon, Icons.mail_outline);
      expect(presentation.target, const InviteInboxTarget());
    });

    test('with no inviter name is a plain row', () {
      final presentation = present('HouseholdInviteReceived', {
        ...household,
        'inviteId': 'i1',
      });

      expect(presentation, plain);
    });
  });

  group('HouseholdInviteAwaitingApproval', () {
    const payload = {
      ...household,
      'inviteId': 'i1',
      'inviterName': 'Ana',
      'inviteeId': 'u2',
      'inviteeName': 'Bo',
      'inviteeEmail': null,
    };

    test('names the inviter in the title and the invitee in the detail', () {
      final presentation = present('HouseholdInviteAwaitingApproval', payload);

      expect(presentation.title, contains('Ana'));
      expect(presentation.title, contains('The Smiths'));
      expect(presentation.detail, contains('Bo'));
      expect(presentation.icon, Icons.how_to_reg_outlined);
    });

    test("opens the household's invites awaiting approval", () {
      final presentation = present('HouseholdInviteAwaitingApproval', payload);

      expect(
        presentation.target,
        const HouseholdInvitesTarget('h1', awaitingApproval: true),
      );
    });

    test('names the address when the invite gave no name', () {
      final presentation = present('HouseholdInviteAwaitingApproval', {
        ...payload,
        'inviteeId': null,
        'inviteeName': null,
        'inviteeEmail': 'bo@x.org',
      });

      expect(presentation.detail, contains('bo@x.org'));
      expect(presentation.target, isNotNull);
    });

    test('says "someone" when the invite gave neither name nor address', () {
      final presentation = present('HouseholdInviteAwaitingApproval', {
        ...payload,
        'inviteeId': null,
        'inviteeName': null,
        'inviteeEmail': null,
      });

      expect(presentation.detail, l10n.notificationInviteeUnnamedDetail);
      expect(presentation.detail, contains('someone'));
      expect(presentation.target, isNotNull);
    });

    test('an invitee name that is not a string falls back to the address', () {
      final presentation = present('HouseholdInviteAwaitingApproval', {
        ...payload,
        'inviteeName': 42,
        'inviteeEmail': 'bo@x.org',
      });

      expect(presentation.detail, contains('bo@x.org'));
    });
  });

  group('HouseholdInviteAccepted', () {
    const payload = {
      ...household,
      'inviteId': 'i1',
      'memberUserId': 'u2',
      'memberName': 'Bo',
    };

    test('names the new member and opens the household', () {
      final presentation = present('HouseholdInviteAccepted', payload);

      expect(presentation.title, contains('Bo'));
      expect(presentation.title, contains('The Smiths'));
      expect(presentation.icon, Icons.group_add_outlined);
      expect(presentation.target, const HouseholdTarget('h1'));
    });

    test('with no member name is a plain row', () {
      final presentation = present('HouseholdInviteAccepted', {
        ...payload,
        'memberName': null,
      });

      expect(presentation, plain);
    });
  });

  group('HouseholdInviteDeclined', () {
    const payload = {
      ...household,
      'inviteId': 'i1',
      'inviteeId': 'u2',
      'inviteeName': 'Bo',
      'inviteeEmail': null,
    };

    test('names the invitee and opens the declined invite', () {
      final presentation = present('HouseholdInviteDeclined', payload);

      expect(presentation.title, contains('Bo'));
      expect(presentation.title, contains('The Smiths'));
      expect(presentation.icon, Icons.person_off_outlined);
      expect(presentation.target, const DeclinedInviteTarget('h1'));
    });

    test('names the address when the invite gave no name', () {
      final presentation = present('HouseholdInviteDeclined', {
        ...payload,
        'inviteeId': null,
        'inviteeName': null,
        'inviteeEmail': 'bo@x.org',
      });

      expect(presentation.title, contains('bo@x.org'));
      expect(presentation.target, const DeclinedInviteTarget('h1'));
    });

    test('says "someone" when the invite gave neither name nor address', () {
      final presentation = present('HouseholdInviteDeclined', {
        ...payload,
        'inviteeId': null,
        'inviteeName': null,
        'inviteeEmail': null,
      });

      expect(
        presentation.title,
        l10n.notificationHouseholdInviteDeclinedUnnamedTitle('The Smiths'),
      );
      expect(presentation.title, contains('Someone'));
      expect(presentation.target, const DeclinedInviteTarget('h1'));
    });
  });

  group('HouseholdOwnershipTransferred', () {
    const payload = {
      ...household,
      'previousOwnerMemberId': 'm1',
      'previousOwnerName': 'Ana',
      'newOwnerMemberId': 'm2',
      'newOwnerName': 'Bo',
    };

    test('names the previous owner and opens the household', () {
      final presentation = present('HouseholdOwnershipTransferred', payload);

      expect(presentation.title, contains('Ana'));
      expect(presentation.title, contains('The Smiths'));
      expect(presentation.icon, Icons.workspace_premium_outlined);
      expect(presentation.target, const HouseholdTarget('h1'));
    });

    test('says "the previous owner" when their user was deleted', () {
      final presentation = present('HouseholdOwnershipTransferred', {
        ...payload,
        'previousOwnerName': null,
      });

      expect(presentation.title, contains('the previous owner'));
      expect(presentation.target, const HouseholdTarget('h1'));
    });
  });

  group('a plain row', () {
    test('unknown type is a plain row', () {
      final presentation = present('SomethingNew', {'anything': 1});

      expect(presentation.target, isNull);
      expect(presentation.title, l10n.notificationUnknownTitle);
      expect(presentation.icon, Icons.notifications_none);
      expect(presentation.detail, isNull);
      expect(presentation.quote, isNull);
    });

    test('MailTestResult is a plain row', () {
      final presentation = present('MailTestResult', {
        'outcome': 'sent',
        'code': null,
        'message': 'The test email was sent.',
      });

      expect(presentation, plain);
    });

    test('household payload missing householdId is a plain row', () {
      final payload = {
        'householdName': 'The Smiths',
        'inviteId': 'i1',
        'inviterName': 'Ana',
      };

      expect(
        () => present('HouseholdInviteReceived', payload),
        returnsNormally,
      );
      expect(present('HouseholdInviteReceived', payload), plain);
    });

    test('householdName that is not a string is a plain row', () {
      final payload = {
        'householdId': 'h1',
        'householdName': 42,
        'memberUserId': 'u2',
        'memberName': 'Bo',
        'inviteId': 'i1',
      };

      expect(
        () => present('HouseholdInviteAccepted', payload),
        returnsNormally,
      );
      expect(present('HouseholdInviteAccepted', payload), plain);
    });

    test('a householdId that is not a string is a plain row', () {
      for (final type in [
        'HouseholdInviteReceived',
        'HouseholdInviteAwaitingApproval',
        'HouseholdInviteAccepted',
        'HouseholdInviteDeclined',
        'HouseholdOwnershipTransferred',
      ]) {
        expect(
          present(type, {
            'householdId': 7,
            'householdName': 'The Smiths',
            'inviterName': 'Ana',
            'memberName': 'Bo',
            'inviteeName': 'Bo',
            'previousOwnerName': 'Ana',
          }),
          plain,
          reason: type,
        );
      }
    });

    test('an empty payload is a plain row for every household type', () {
      for (final type in [
        'HouseholdInviteReceived',
        'HouseholdInviteAwaitingApproval',
        'HouseholdInviteAccepted',
        'HouseholdInviteDeclined',
        'HouseholdOwnershipTransferred',
      ]) {
        expect(present(type, const {}), plain, reason: type);
      }
    });
  });

  group('targets', () {
    test('compare by value', () {
      expect(const HouseholdTarget('h1'), const HouseholdTarget('h1'));
      expect(const HouseholdTarget('h1'), isNot(const HouseholdTarget('h2')));
      expect(
        const HouseholdInvitesTarget('h1', awaitingApproval: true),
        isNot(const HouseholdInvitesTarget('h1', awaitingApproval: false)),
      );
      expect(
        const DeclinedInviteTarget('h1'),
        isNot(const HouseholdTarget('h1')),
      );
      expect(const InviteInboxTarget(), const InviteInboxTarget());
    });
  });
}
