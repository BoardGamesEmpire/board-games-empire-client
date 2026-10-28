import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The role table (#498): what each role may do to an event, asserted set by
/// set. The expectations are written out here rather than derived from the
/// implementation, so the table can't drift without a test saying so.
void main() {
  // Spelled out so a change to a set shows up in the diff of this file.
  const rsvp = {EventAction.rsvp};

  const organizer = {
    EventAction.edit,
    EventAction.addDate,
    EventAction.editDate,
    EventAction.rsvp,
    EventAction.manageAttendees,
  };

  const moderator = {
    EventAction.edit,
    EventAction.editDate,
    EventAction.cancelDate,
    EventAction.rsvp,
    EventAction.manageAttendees,
    EventAction.resolveNomination,
  };

  const household = {
    EventAction.edit,
    EventAction.addDate,
    EventAction.editDate,
    EventAction.confirmDate,
    EventAction.declineDate,
    EventAction.cancelDate,
    EventAction.manageAttendees,
    EventAction.resolveNomination,
  };

  /// The host holds every action, so a new [EventAction] fails the host and
  /// co-host rows until the table says who else gets it.
  final everything = EventAction.values.toSet();

  /// Every event role's set. A role missing from here fails the test below,
  /// so adding one to [EventRole] means deciding what it may do.
  final byEventRole = <EventRole, Set<EventAction>>{
    EventRole.host: everything,
    // No `delete`, which the catalog gives the host alone, and no `archive`,
    // whose permission condition names the host alone, so a co-host's archive
    // is always refused.
    EventRole.coHost: everything.difference({
      EventAction.delete,
      EventAction.archive,
    }),
    EventRole.organizer: organizer,
    EventRole.moderator: moderator,
    EventRole.participant: rsvp,
    EventRole.guest: rsvp,
    EventRole.spectator: rsvp,
    EventRole.unknown: const {},
  };

  /// What a household role adds on a household event. Same rule as above.
  final byHouseholdRole = <HouseholdRole, Set<EventAction>>{
    HouseholdRole.householdOwner: household,
    HouseholdRole.householdAdmin: household,
    HouseholdRole.householdMember: const {},
    HouseholdRole.householdGuest: const {},
    HouseholdRole.unknown: const {},
  };

  final plain = item('e-plain').event;
  final inHousehold = item('e-household', householdId: 'h-1').event;

  test('every event role and household role has a row in the table', () {
    expect(byEventRole.keys, unorderedEquals(EventRole.values));
    expect(byHouseholdRole.keys, unorderedEquals(HouseholdRole.values));
  });

  test('answers a set nothing can change', () {
    // A screen state compares by it, so it must not change under one.
    final actions = eventActionsFor(plain, eventRole: EventRole.host);

    expect(actions.clear, throwsUnsupportedError);
  });

  group('an event role', () {
    for (final role in EventRole.values) {
      test('${role.name} gets its row of the table', () {
        expect(eventActionsFor(plain, eventRole: role), byEventRole[role]);
      });

      test('${role.name} gets the same on a household event', () {
        expect(
          eventActionsFor(inHousehold, eventRole: role),
          byEventRole[role],
        );
      });
    }

    test('left out gets nothing', () {
      expect(eventActionsFor(plain), isEmpty);
      expect(eventActionsFor(inHousehold), isEmpty);
    });

    test('is the host alone who may delete', () {
      final who = [
        for (final role in EventRole.values)
          if (eventActionsFor(
            plain,
            eventRole: role,
          ).contains(EventAction.delete))
            role,
      ];

      expect(who, [EventRole.host]);
    });

    test('is the host and co-host who may remove a date', () {
      final who = [
        for (final role in EventRole.values)
          if (eventActionsFor(
            plain,
            eventRole: role,
          ).contains(EventAction.removeDate))
            role,
      ];

      expect(who, [EventRole.host, EventRole.coHost]);
    });

    test('a household owner or admin may edit a date but not remove one', () {
      for (final role in [
        HouseholdRole.householdOwner,
        HouseholdRole.householdAdmin,
      ]) {
        final actions = eventActionsFor(inHousehold, householdRole: role);

        expect(actions, contains(EventAction.editDate));
        expect(actions, isNot(contains(EventAction.removeDate)));
      }
    });

    test('is the host alone who may archive', () {
      final who = [
        for (final role in EventRole.values)
          if (eventActionsFor(
            plain,
            eventRole: role,
          ).contains(EventAction.archive))
            role,
      ];

      expect(who, [EventRole.host]);
    });
  });

  group('a household role', () {
    for (final role in HouseholdRole.values) {
      test('${role.name} on a household event gets its row', () {
        expect(
          eventActionsFor(inHousehold, householdRole: role),
          byHouseholdRole[role],
        );
      });
    }

    test('an owner who also attends gets the union', () {
      expect(
        eventActionsFor(
          inHousehold,
          eventRole: EventRole.participant,
          householdRole: HouseholdRole.householdOwner,
        ),
        {...household, EventAction.rsvp},
      );
    });

    test('an owner who hosts gets what the host gets', () {
      expect(
        eventActionsFor(
          inHousehold,
          eventRole: EventRole.host,
          householdRole: HouseholdRole.householdOwner,
        ),
        everything,
      );
    });

    test('counts only on a household event', () {
      expect(
        eventActionsFor(plain, householdRole: HouseholdRole.householdOwner),
        isEmpty,
      );
      expect(
        eventActionsFor(plain, householdRole: HouseholdRole.householdAdmin),
        isEmpty,
      );
    });

    test('members and guests add nothing', () {
      for (final role in [
        HouseholdRole.householdMember,
        HouseholdRole.householdGuest,
      ]) {
        expect(
          eventActionsFor(
            inHousehold,
            eventRole: EventRole.participant,
            householdRole: role,
          ),
          rsvp,
        );
      }
    });

    test('unknown adds nothing', () {
      expect(
        eventActionsFor(
          inHousehold,
          eventRole: EventRole.participant,
          householdRole: HouseholdRole.unknown,
        ),
        rsvp,
      );
    });
  });

  group('a local-only event', () {
    final local = item(
      'e-local',
      householdId: 'h-1',
    ).event.copyWith(isLocalOnly: true);

    test('offers its host nothing, as the server does not know it yet', () {
      expect(eventActionsFor(local, eventRole: EventRole.host), isEmpty);
    });

    test('offers a household owner nothing either', () {
      expect(
        eventActionsFor(local, householdRole: HouseholdRole.householdOwner),
        isEmpty,
      );
    });
  });
}
