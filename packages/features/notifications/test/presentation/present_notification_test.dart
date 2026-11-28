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

  group('DataGatewayAutoDisabled', () {
    const payload = <String, Object?>{
      'gatewayId': 'g1',
      'gatewayName': 'BoardGameGeek',
      'reason': 'repeated_connection_failure',
      'consecutiveFailures': 5,
      'firstFailureAt': '2026-11-27T10:00:00.000Z',
      'lastFailureAt': '2026-11-27T10:05:00.000Z',
      'lastError': 'connect ECONNREFUSED 10.0.0.7:443',
    };

    test('names the DataGateway in the title and opens it', () {
      final presentation = present('DataGatewayAutoDisabled', payload);

      expect(presentation.title, contains('BoardGameGeek'));
      expect(presentation.icon, Icons.power_off_outlined);
      expect(presentation.target, const DataGatewayTarget('g1'));
    });

    test('words repeated_connection_failure', () {
      final presentation = present('DataGatewayAutoDisabled', payload);

      expect(presentation.detail, l10n.notificationDataGatewayConnectDetail);
      expect(presentation.detail, contains("couldn't connect"));
    });

    test('words repeated_call_failure', () {
      final presentation = present('DataGatewayAutoDisabled', {
        ...payload,
        'reason': 'repeated_call_failure',
      });

      expect(presentation.detail, l10n.notificationDataGatewayCallDetail);
      expect(presentation.detail, contains('calls kept failing'));
    });

    test('words a reason it does not know, and one that is not a string', () {
      for (final reason in <Object?>['rate_limited', 7, null, '']) {
        final presentation = present('DataGatewayAutoDisabled', {
          ...payload,
          'reason': reason,
        });

        expect(
          presentation.detail,
          l10n.notificationDataGatewayGenericDetail,
          reason: '$reason',
        );
        expect(presentation.target, const DataGatewayTarget('g1'));
      }
    });

    test('the quote is lastError, as the upstream wrote it', () {
      const error = '  Verbindung verweigert:\n\tECONNREFUSED  ';
      final presentation = present('DataGatewayAutoDisabled', {
        ...payload,
        'lastError': error,
      });

      expect(presentation.quote, error);
      expect(presentation.title, isNot(contains('Verbindung')));
      expect(presentation.detail, isNot(contains('Verbindung')));
    });

    test('with no lastError has no quote but is still a row', () {
      final presentation = present('DataGatewayAutoDisabled', {
        ...payload,
        'lastError': null,
      });

      expect(presentation.quote, isNull);
      expect(presentation.title, contains('BoardGameGeek'));
      expect(presentation.target, const DataGatewayTarget('g1'));
    });

    test('missing required field is a plain row', () {
      expect(
        present('DataGatewayAutoDisabled', {...payload, 'gatewayId': null}),
        plain,
      );
      expect(
        present('DataGatewayAutoDisabled', {...payload, 'gatewayName': 3}),
        plain,
      );
      expect(present('DataGatewayAutoDisabled', const {}), plain);
    });
  });

  group('DataGatewayCapabilitiesLost', () {
    const payload = <String, Object?>{
      'gatewayId': 'g1',
      'gatewayName': 'BoardGameGeek',
      'lostCapabilities': ['Search', 'Fetch'],
    };

    test('names the DataGateway and opens it', () {
      final presentation = present('DataGatewayCapabilitiesLost', payload);

      expect(presentation.title, contains('BoardGameGeek'));
      expect(presentation.icon, Icons.extension_off_outlined);
      expect(presentation.target, const DataGatewayTarget('g1'));
      expect(presentation.quote, isNull);
    });

    test('counts the capabilities lost, in the plural', () {
      expect(
        present('DataGatewayCapabilitiesLost', payload).detail,
        l10n.notificationDataGatewayCapabilitiesLostDetail(2),
      );
      expect(
        present('DataGatewayCapabilitiesLost', {
          ...payload,
          'lostCapabilities': ['Search'],
        }).detail,
        l10n.notificationDataGatewayCapabilitiesLostDetail(1),
      );
      expect(
        l10n.notificationDataGatewayCapabilitiesLostDetail(1),
        contains('1 '),
      );
      expect(
        l10n.notificationDataGatewayCapabilitiesLostDetail(2),
        contains('2 '),
      );
    });

    test('counts only the entries that are text', () {
      final presentation = present('DataGatewayCapabilitiesLost', {
        ...payload,
        'lostCapabilities': ['Search', 4, null, '', 'Fetch'],
      });

      expect(
        presentation.detail,
        l10n.notificationDataGatewayCapabilitiesLostDetail(2),
      );
    });

    test('an empty list is a row with no detail', () {
      final presentation = present('DataGatewayCapabilitiesLost', {
        ...payload,
        'lostCapabilities': <Object?>[],
      });

      expect(presentation.detail, isNull);
      expect(presentation.target, const DataGatewayTarget('g1'));
    });

    test('missing required field is a plain row', () {
      expect(
        present('DataGatewayCapabilitiesLost', {...payload, 'gatewayId': ''}),
        plain,
      );
      expect(
        present('DataGatewayCapabilitiesLost', {
          ...payload,
          'gatewayName': null,
        }),
        plain,
      );
      expect(
        present('DataGatewayCapabilitiesLost', {
          'gatewayId': 'g1',
          'gatewayName': 'BoardGameGeek',
        }),
        plain,
      );
      expect(
        present('DataGatewayCapabilitiesLost', {
          ...payload,
          'lostCapabilities': 'Search',
        }),
        plain,
      );
      expect(present('DataGatewayCapabilitiesLost', const {}), plain);
    });
  });

  group('UsernameVariantAssigned', () {
    const payload = <String, Object?>{
      'username': 'jason-2',
      'requestedUsername': 'jason',
      'usernameChangeAllowed': true,
    };

    test('names both usernames as-is and opens nothing', () {
      final presentation = present('UsernameVariantAssigned', payload);

      expect(
        presentation.title,
        l10n.notificationUsernameVariantAssignedTitle('jason-2', 'jason'),
      );
      expect(presentation.title, contains('jason-2'));
      expect(presentation.title, contains('jason'));
      expect(presentation.icon, Icons.alternate_email);
      expect(presentation.quote, isNull);
      expect(presentation.target, isNull);
    });

    test('inserts a username with markup or spaces unchanged', () {
      final presentation = present('UsernameVariantAssigned', {
        ...payload,
        'username': ' <b>j{0}</b> ',
        'requestedUsername': "O'Neil",
      });

      expect(
        presentation.title,
        l10n.notificationUsernameVariantAssignedTitle(
          ' <b>j{0}</b> ',
          "O'Neil",
        ),
      );
    });

    test('says they can change it when the server allows it', () {
      expect(
        present('UsernameVariantAssigned', payload).detail,
        l10n.notificationUsernameVariantAssignedChangeAllowedDetail,
      );
    });

    test('says a server admin can change it when the server does not', () {
      expect(
        present('UsernameVariantAssigned', {
          ...payload,
          'usernameChangeAllowed': false,
        }).detail,
        l10n.notificationUsernameVariantAssignedChangeNotAllowedDetail,
      );
    });

    test('a usernameChangeAllowed that is not a bool counts as false', () {
      for (final value in <Object?>[null, 'true', 1, 'yes']) {
        final presentation = present('UsernameVariantAssigned', {
          ...payload,
          'usernameChangeAllowed': value,
        });

        expect(
          presentation.detail,
          l10n.notificationUsernameVariantAssignedChangeNotAllowedDetail,
          reason: '$value',
        );
        expect(presentation.title, isNot(l10n.notificationUnknownTitle));
      }

      final missing = Map<String, Object?>.of(payload)
        ..remove('usernameChangeAllowed');
      expect(
        present('UsernameVariantAssigned', missing).detail,
        l10n.notificationUsernameVariantAssignedChangeNotAllowedDetail,
      );
    });

    test('missing required field is a plain row', () {
      expect(
        present('UsernameVariantAssigned', {...payload, 'username': null}),
        plain,
      );
      expect(
        present('UsernameVariantAssigned', {...payload, 'username': ' '}),
        plain,
      );
      expect(
        present('UsernameVariantAssigned', {
          ...payload,
          'requestedUsername': 3,
        }),
        plain,
      );
      expect(
        present('UsernameVariantAssigned', {
          'username': 'jason-2',
          'usernameChangeAllowed': true,
        }),
        plain,
      );
      expect(present('UsernameVariantAssigned', const {}), plain);
    });
  });

  group('event notifications that open the event', () {
    const event = <String, Object?>{
      'eventId': 'e1',
      'eventTitle': 'Friday Night Games',
    };

    test('EventCreated names the event and opens it', () {
      final presentation = present('EventCreated', event);

      expect(
        presentation.title,
        l10n.notificationEventCreatedTitle('Friday Night Games'),
      );
      expect(presentation.title, contains('Friday Night Games'));
      expect(presentation.target, const EventTarget('e1'));
      expect(presentation.icon, Icons.event_outlined);
    });

    test('EventReopened names the event and opens it', () {
      final presentation = present('EventReopened', event);

      expect(
        presentation.title,
        l10n.notificationEventReopenedTitle('Friday Night Games'),
      );
      expect(presentation.title, contains('reopened'));
      expect(presentation.target, const EventTarget('e1'));
    });

    test('EventCancelled quotes the reason as the host wrote it', () {
      const reason = '  Wasserschaden im <Keller>  ';
      final presentation = present('EventCancelled', {
        ...event,
        'reason': reason,
      });

      expect(
        presentation.title,
        l10n.notificationEventCancelledTitle('Friday Night Games'),
      );
      expect(presentation.title, contains('cancelled'));
      expect(presentation.quote, reason);
      expect(presentation.target, const EventTarget('e1'));
    });

    test('EventCancelled with a null or non-string reason has no quote', () {
      for (final reason in <Object?>[null, '', '   ', 4]) {
        final presentation = present('EventCancelled', {
          ...event,
          'reason': reason,
        });

        expect(presentation.quote, isNull, reason: '$reason');
        expect(presentation.target, const EventTarget('e1'));
      }
      expect(present('EventCancelled', event).quote, isNull);
    });

    test('EventRsvpReceived names the attendee and opens the event', () {
      final presentation = present('EventRsvpReceived', {
        ...event,
        'attendeeName': 'Ana',
      });

      expect(
        presentation.title,
        l10n.notificationEventRsvpReceivedTitle('Ana', 'Friday Night Games'),
      );
      expect(presentation.title, contains('Ana'));
      expect(presentation.target, const EventTarget('e1'));
    });

    test('EventRsvpReceived with no attendee name says a guest', () {
      for (final name in <Object?>[null, '', '   ']) {
        final presentation = present('EventRsvpReceived', {
          ...event,
          'attendeeName': name,
        });

        expect(
          presentation.title,
          l10n.notificationEventRsvpReceivedGuestTitle('Friday Night Games'),
          reason: '$name',
        );
        expect(presentation.title, contains('A guest'));
        expect(presentation.target, const EventTarget('e1'));
      }
      expect(
        present('EventRsvpReceived', event).title,
        contains('A guest'),
      );
    });

    test('EventRsvpChanged names who changed it and the new answer', () {
      final presentation = present('EventRsvpChanged', {
        ...event,
        'changedByName': 'Bo',
        'status': 'NotAttending',
      });

      expect(
        presentation.title,
        l10n.notificationEventRsvpChangedTitle('Bo', 'Friday Night Games'),
      );
      expect(
        presentation.detail,
        l10n.notificationEventRsvpNowNotAttendingDetail,
      );
      expect(presentation.target, const EventTarget('e1'));
    });

    test('EventRsvpChanged words each answer', () {
      const words = {
        'Attending': 'Now: Going',
        'Maybe': 'Now: Maybe',
        'NotAttending': 'Now: Not going',
        'Invited': 'Now: Invited',
      };
      for (final MapEntry(:key, :value) in words.entries) {
        final presentation = present('EventRsvpChanged', {
          ...event,
          'changedByName': 'Bo',
          'status': key,
        });

        expect(presentation.detail, value, reason: key);
      }
    });

    test('EventRsvpChanged with a status it does not know has no detail', () {
      for (final status in <Object?>['Waitlisted', 2, null]) {
        final presentation = present('EventRsvpChanged', {
          ...event,
          'changedByName': 'Bo',
          'status': status,
        });

        expect(presentation.detail, isNull, reason: '$status');
        expect(presentation.target, const EventTarget('e1'));
      }
    });

    test('EventRsvpChanged with no name gives the generic wording', () {
      for (final name in <Object?>[null, '', '   ']) {
        final presentation = present('EventRsvpChanged', {
          ...event,
          'changedByName': name,
          'status': 'Maybe',
        });

        expect(
          presentation.title,
          l10n.notificationEventRsvpChangedUnnamedTitle('Friday Night Games'),
          reason: '$name',
        );
        expect(presentation.detail, 'Now: Maybe');
        expect(presentation.target, const EventTarget('e1'));
      }
    });

    test('EventRsvpReceived with a name that is not text is a plain row', () {
      for (final name in <Object?>[
        3,
        true,
        1.5,
        const ['Ana'],
        const {},
      ]) {
        expect(
          present('EventRsvpReceived', {...event, 'attendeeName': name}),
          plain,
          reason: '$name',
        );
      }
    });

    test('EventRsvpChanged with a name that is not text is a plain row', () {
      for (final name in <Object?>[
        3,
        true,
        1.5,
        const ['Bo'],
        const {},
      ]) {
        expect(
          present('EventRsvpChanged', {
            ...event,
            'changedByName': name,
            'status': 'Maybe',
          }),
          plain,
          reason: '$name',
        );
      }
    });

    test('EventInviteAccepted names the invitee and opens the event', () {
      final presentation = present('EventInviteAccepted', {
        ...event,
        'inviteId': 'i1',
        'inviteeName': 'Cy',
      });

      expect(
        presentation.title,
        l10n.notificationEventInviteAcceptedTitle('Cy', 'Friday Night Games'),
      );
      expect(presentation.title, contains('accepted'));
      expect(presentation.target, const EventTarget('e1'));
    });

    test('EventInviteDeclined names the invitee and opens the event', () {
      final presentation = present('EventInviteDeclined', {
        ...event,
        'inviteId': 'i1',
        'inviteeName': 'Cy',
      });

      expect(
        presentation.title,
        l10n.notificationEventInviteDeclinedTitle('Cy', 'Friday Night Games'),
      );
      expect(presentation.title, contains('declined'));
      expect(presentation.target, const EventTarget('e1'));
    });

    test('names and titles go in unchanged', () {
      const title = '  {Spiel} <b>Abend</b> \u{00DF}  ';
      final presentation = present('EventRsvpReceived', {
        'eventId': 'e1',
        'eventTitle': title,
        'attendeeName': '{who} <i>',
      });

      expect(presentation.title, contains(title));
      expect(presentation.title, contains('{who} <i>'));
    });

    test('missing required field is a plain row', () {
      for (final type in [
        'EventCreated',
        'EventReopened',
        'EventCancelled',
        'EventRsvpReceived',
        'EventRsvpChanged',
        'EventInviteAccepted',
        'EventInviteDeclined',
      ]) {
        const full = <String, Object?>{
          'eventId': 'e1',
          'eventTitle': 'Friday Night Games',
          'attendeeName': 'Ana',
          'changedByName': 'Bo',
          'status': 'Maybe',
          'inviteeName': 'Cy',
        };
        expect(present(type, full), isNot(plain), reason: type);
        expect(present(type, {...full, 'eventId': null}), plain, reason: type);
        expect(present(type, {...full, 'eventId': 5}), plain, reason: type);
        expect(
          present(type, {...full, 'eventTitle': null}),
          plain,
          reason: type,
        );
        expect(present(type, const {}), plain, reason: type);
      }
      expect(
        present('EventInviteAccepted', {...event, 'inviteeName': null}),
        plain,
      );
      expect(
        present('EventInviteDeclined', {...event, 'inviteeName': ''}),
        plain,
      );
    });
  });

  group('event notifications that open nothing', () {
    const event = <String, Object?>{
      'eventId': 'e1',
      'eventTitle': 'Friday Night Games',
    };

    test('EventDeleted says what happened and opens nothing', () {
      final presentation = present('EventDeleted', event);

      expect(
        presentation.title,
        l10n.notificationEventDeletedTitle('Friday Night Games'),
      );
      expect(presentation.title, contains('deleted'));
      expect(presentation.target, isNull);
    });

    test('EventAttendeeRemoved says what happened and opens nothing', () {
      final presentation = present('EventAttendeeRemoved', event);

      expect(
        presentation.title,
        l10n.notificationEventAttendeeRemovedTitle('Friday Night Games'),
      );
      expect(presentation.title, contains('removed'));
      expect(presentation.target, isNull);
    });

    test('EventInviteReceived is a row with no destination', () {
      final presentation = present('EventInviteReceived', {
        ...event,
        'inviteId': 'i1',
        'inviterName': 'Ana',
      });

      expect(
        presentation.title,
        l10n.notificationEventInviteReceivedTitle('Ana', 'Friday Night Games'),
      );
      expect(presentation.title, contains('invited you'));
      expect(presentation.target, isNull);
    });

    test('missing required field is a plain row', () {
      for (final type in [
        'EventDeleted',
        'EventAttendeeRemoved',
        'EventInviteReceived',
      ]) {
        const full = <String, Object?>{
          'eventId': 'e1',
          'eventTitle': 'Friday Night Games',
          'inviterName': 'Ana',
        };
        expect(present(type, full), isNot(plain), reason: type);
        expect(present(type, {...full, 'eventId': null}), plain, reason: type);
        expect(
          present(type, {...full, 'eventTitle': 7}),
          plain,
          reason: type,
        );
        expect(present(type, const {}), plain, reason: type);
      }
      expect(
        present('EventInviteReceived', {...event, 'inviterName': null}),
        plain,
      );
    });
  });

  group('date notifications', () {
    const payload = <String, Object?>{
      'eventId': 'e1',
      'eventTitle': 'Friday Night Games',
      'occurrenceId': 'o1',
      'occurrenceLabel': 'Saturday Evening',
    };
    const target = EventTarget('e1', tab: 'games', date: 'o1');

    const titles = {
      'EventOccurrenceProposed': 'proposed',
      'EventOccurrenceConfirmed': 'confirmed',
      'EventOccurrenceDeclined': 'declined',
      'EventOccurrenceCanceled': 'cancelled',
      'EventOccurrenceRescheduled': 'rescheduled',
    };

    for (final MapEntry(:key, :value) in titles.entries) {
      test('$key names the event, shows the date, and opens it', () {
        final presentation = present(key, payload);

        expect(presentation.title, contains('Friday Night Games'));
        expect(presentation.title, contains(value));
        expect(presentation.detail, 'Date: Saturday Evening');
        expect(presentation.target, target);
      });

      test('$key with a null occurrenceLabel has no detail', () {
        for (final label in <Object?>[null, '', '  ', 5]) {
          final presentation = present(key, {
            ...payload,
            'occurrenceLabel': label,
          });

          expect(presentation.detail, isNull, reason: '$label');
          expect(presentation.target, target, reason: '$label');
        }
        final absent = {...payload}..remove('occurrenceLabel');
        expect(present(key, absent).target, target);
      });

      test('$key missing required field is a plain row', () {
        expect(present(key, {...payload, 'occurrenceId': null}), plain);
        expect(present(key, {...payload, 'occurrenceId': 3}), plain);
        expect(present(key, {...payload, 'eventId': null}), plain);
        expect(present(key, {...payload, 'eventTitle': null}), plain);
        expect(present(key, const {}), plain);
      });
    }

    test('words each date notification differently', () {
      final seen = {
        for (final type in titles.keys) present(type, payload).title,
      };

      expect(seen, hasLength(titles.length));
    });

    test('the date label goes in unchanged', () {
      final presentation = present('EventOccurrenceConfirmed', {
        ...payload,
        'occurrenceLabel': '  {Freitag} <b>4.</b>  ',
      });

      expect(presentation.detail, 'Date:   {Freitag} <b>4.</b>  ');
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
      expect(const DataGatewayTarget('g1'), const DataGatewayTarget('g1'));
      expect(
        const DataGatewayTarget('g1'),
        isNot(const DataGatewayTarget('g2')),
      );
      expect(
        const DataGatewayTarget('g1'),
        isNot(const HouseholdTarget('g1')),
      );
      expect(const EventTarget('e1'), const EventTarget('e1'));
      expect(
        const EventTarget('e1', tab: 'games', date: 'o1'),
        const EventTarget('e1', tab: 'games', date: 'o1'),
      );
      expect(const EventTarget('e1'), isNot(const EventTarget('e2')));
      expect(
        const EventTarget('e1'),
        isNot(const EventTarget('e1', tab: 'games')),
      );
      expect(
        const EventTarget('e1', tab: 'games', date: 'o1'),
        isNot(const EventTarget('e1', tab: 'games', date: 'o2')),
      );
    });
  });
}
