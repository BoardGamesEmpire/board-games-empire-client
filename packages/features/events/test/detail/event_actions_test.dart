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

  // A guest answers for themselves, on the invitation and on the proposed
  // dates (#507), and manages their own offered games (#516). Nominating and
  // voting on games is not theirs (#517).
  const guest = {
    EventAction.rsvp,
    EventAction.voteAvailability,
    EventAction.offerGame,
  };

  // A participant holds the guest's set and nominates and votes on games.
  const participant = {
    ...guest,
    EventAction.nominateGame,
    EventAction.voteGame,
  };

  const organizer = {
    EventAction.edit,
    EventAction.addDate,
    EventAction.editDate,
    EventAction.voteAvailability,
    EventAction.rsvp,
    EventAction.manageAttendees,
    EventAction.offerGame,
  };

  const moderator = {
    EventAction.edit,
    EventAction.editDate,
    EventAction.cancelDate,
    EventAction.rsvp,
    EventAction.manageAttendees,
    EventAction.resolveNomination,
    EventAction.offerGame,
  };

  const household = {
    EventAction.edit,
    EventAction.cancel,
    EventAction.addDate,
    EventAction.editDate,
    EventAction.confirmDate,
    EventAction.declineDate,
    EventAction.cancelDate,
    EventAction.manageAttendees,
    EventAction.resolveNomination,
    EventAction.offerGame,
  };

  /// The host holds every action, so a new [EventAction] fails the host and
  /// co-host rows until the table says who else gets it.
  final everything = EventAction.values.toSet();

  // Every action but `delete`, which the catalog gives the host alone. The
  // co-host holds both status grants (#502).
  const coHost = {
    EventAction.edit,
    EventAction.cancel,
    EventAction.archive,
    EventAction.addDate,
    EventAction.editDate,
    EventAction.confirmDate,
    EventAction.declineDate,
    EventAction.cancelDate,
    EventAction.removeDate,
    EventAction.voteAvailability,
    EventAction.rsvp,
    EventAction.manageAttendees,
    EventAction.approveGame,
    EventAction.rejectGame,
    EventAction.resolveNomination,
    EventAction.nominateGame,
    EventAction.voteGame,
    EventAction.offerGame,
  };

  /// Every event role's set. A role missing from here fails the test below,
  /// so adding one to [EventRole] means deciding what it may do.
  final byEventRole = <EventRole, Set<EventAction>>{
    EventRole.host: everything,
    EventRole.coHost: coHost,
    EventRole.organizer: organizer,
    EventRole.moderator: moderator,
    EventRole.participant: participant,
    EventRole.guest: guest,
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

    test("voteAvailability is the host's, co-host's, organizer's, "
        "participant's and guest's", () {
      final who = [
        for (final role in EventRole.values)
          if (eventActionsFor(
            plain,
            eventRole: role,
          ).contains(EventAction.voteAvailability))
            role,
      ];

      expect(who, [
        EventRole.host,
        EventRole.coHost,
        EventRole.organizer,
        EventRole.participant,
        EventRole.guest,
      ]);
    });

    test("nominateGame and voteGame are the host's, co-host's and "
        "participant's, and no guest's (#517)", () {
      for (final action in [EventAction.nominateGame, EventAction.voteGame]) {
        final who = [
          for (final role in EventRole.values)
            if (eventActionsFor(plain, eventRole: role).contains(action)) role,
        ];

        expect(who, [
          EventRole.host,
          EventRole.coHost,
          EventRole.participant,
        ]);
      }
    });

    test(
      "offerGame is every attending role's but the spectator's (#516)",
      () {
        final who = [
          for (final role in EventRole.values)
            if (eventActionsFor(
              plain,
              eventRole: role,
            ).contains(EventAction.offerGame))
              role,
        ];

        expect(who, [
          EventRole.host,
          EventRole.coHost,
          EventRole.organizer,
          EventRole.moderator,
          EventRole.participant,
          EventRole.guest,
        ]);
      },
    );

    test('a moderator, spectator or household owner may not vote', () {
      expect(
        eventActionsFor(plain, eventRole: EventRole.moderator),
        isNot(contains(EventAction.voteAvailability)),
      );
      expect(
        eventActionsFor(plain, eventRole: EventRole.spectator),
        isNot(contains(EventAction.voteAvailability)),
      );
      expect(
        eventActionsFor(
          inHousehold,
          householdRole: HouseholdRole.householdOwner,
        ),
        isNot(contains(EventAction.voteAvailability)),
      );
    });

    test('is the host and co-host who may cancel and archive', () {
      for (final action in [EventAction.cancel, EventAction.archive]) {
        final who = [
          for (final role in EventRole.values)
            if (eventActionsFor(plain, eventRole: role).contains(action)) role,
        ];

        expect(who, [EventRole.host, EventRole.coHost], reason: '$action');
      }
    });

    test('the host and co-host sets are the full sets', () {
      expect(
        eventActionsFor(plain, eventRole: EventRole.host),
        equals(EventAction.values.toSet()),
      );
      expect(
        eventActionsFor(plain, eventRole: EventRole.coHost),
        equals(coHost),
      );
      // The co-host's set is spelled out, and is every action but `delete`,
      // so an action added for the host and forgotten on the co-host fails.
      expect(coHost, everything.difference({EventAction.delete}));
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
        {...household, ...participant},
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
          participant,
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
        participant,
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

  group('attendee reach (#510)', () {
    EventAttendee row(String id, EventRole? role) => EventAttendee(
      id: id,
      eventId: 'e-plain',
      status: EventParticipationStatus.attending,
      role: role,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    group('attendeeReachFor', () {
      test('the host and a co-host reach every role', () {
        for (final role in [EventRole.host, EventRole.coHost]) {
          expect(
            attendeeReachFor(plain, eventRole: role),
            AttendeeReach.allRoles,
          );
        }
      });

      test('an organizer and a moderator reach the attending roles', () {
        for (final role in [EventRole.organizer, EventRole.moderator]) {
          expect(
            attendeeReachFor(plain, eventRole: role),
            AttendeeReach.attendingRoles,
          );
        }
      });

      test('a participant, guest, spectator, unknown and null reach none', () {
        for (final role in [
          EventRole.participant,
          EventRole.guest,
          EventRole.spectator,
          EventRole.unknown,
          null,
        ]) {
          expect(attendeeReachFor(plain, eventRole: role), AttendeeReach.none);
        }
      });

      test('a household owner or admin reaches every role on a household '
          'event', () {
        for (final role in [
          HouseholdRole.householdOwner,
          HouseholdRole.householdAdmin,
        ]) {
          expect(
            attendeeReachFor(inHousehold, householdRole: role),
            AttendeeReach.allRoles,
          );
          expect(
            attendeeReachFor(plain, householdRole: role),
            AttendeeReach.none,
          );
        }
      });

      test('an organizer who is also a household admin reaches every role', () {
        expect(
          attendeeReachFor(
            inHousehold,
            eventRole: EventRole.organizer,
            householdRole: HouseholdRole.householdAdmin,
          ),
          AttendeeReach.allRoles,
        );
      });

      test('a local-only event reaches none', () {
        final local = inHousehold.copyWith(isLocalOnly: true);

        expect(
          attendeeReachFor(
            local,
            eventRole: EventRole.host,
            householdRole: HouseholdRole.householdOwner,
          ),
          AttendeeReach.none,
        );
      });
    });

    group('assignableEventRoles', () {
      test('none gives nothing', () {
        expect(assignableEventRoles(AttendeeReach.none), isEmpty);
      });

      test('attendingRoles gives participant, guest and spectator', () {
        expect(assignableEventRoles(AttendeeReach.attendingRoles), [
          EventRole.participant,
          EventRole.guest,
          EventRole.spectator,
        ]);
      });

      test('allRoles adds co-host, organizer and moderator, never host', () {
        expect(assignableEventRoles(AttendeeReach.allRoles), [
          EventRole.participant,
          EventRole.guest,
          EventRole.spectator,
          EventRole.coHost,
          EventRole.organizer,
          EventRole.moderator,
        ]);
      });

      test('answers a list nothing can change', () {
        expect(
          assignableEventRoles(AttendeeReach.allRoles).clear,
          throwsUnsupportedError,
        );
      });
    });

    group('canRemoveAttendee', () {
      test('allRoles removes a co-host but not the host', () {
        expect(
          canRemoveAttendee(
            AttendeeReach.allRoles,
            row('a', EventRole.coHost),
            viewerAttendeeId: 'me',
          ),
          isTrue,
        );
        expect(
          canRemoveAttendee(
            AttendeeReach.allRoles,
            row('a', EventRole.host),
            viewerAttendeeId: 'me',
          ),
          isFalse,
        );
      });

      test('attendingRoles removes a guest but not the host, a co-host, an '
          'organizer or an unknown role', () {
        bool can(EventRole? role) => canRemoveAttendee(
          AttendeeReach.attendingRoles,
          row('a', role),
          viewerAttendeeId: 'me',
        );

        expect(can(EventRole.guest), isTrue);
        expect(can(EventRole.host), isFalse);
        expect(can(EventRole.coHost), isFalse);
        expect(can(EventRole.organizer), isFalse);
        expect(can(EventRole.unknown), isFalse);
        expect(can(null), isFalse);
      });

      test('allRoles does not remove a null or unknown role', () {
        for (final role in [null, EventRole.unknown]) {
          expect(
            canRemoveAttendee(
              AttendeeReach.allRoles,
              row('a', role),
              viewerAttendeeId: 'me',
            ),
            isFalse,
          );
        }
      });

      test('none removes nothing', () {
        expect(
          canRemoveAttendee(
            AttendeeReach.none,
            row('a', EventRole.guest),
            viewerAttendeeId: 'me',
          ),
          isFalse,
        );
      });

      test("no reach removes the viewer's own row", () {
        for (final reach in AttendeeReach.values) {
          expect(
            canRemoveAttendee(
              reach,
              row('me', EventRole.guest),
              viewerAttendeeId: 'me',
            ),
            isFalse,
          );
        }
      });
    });

    group('canSetAnswerFor', () {
      test("the host's row under attendingRoles is answerable", () {
        expect(
          canSetAnswerFor(
            AttendeeReach.attendingRoles,
            row('a', EventRole.host),
            viewerAttendeeId: 'me',
          ),
          isTrue,
        );
      });

      test("the viewer's own row is not", () {
        expect(
          canSetAnswerFor(
            AttendeeReach.allRoles,
            row('me', EventRole.host),
            viewerAttendeeId: 'me',
          ),
          isFalse,
        );
      });

      test('no row is under none', () {
        expect(
          canSetAnswerFor(
            AttendeeReach.none,
            row('a', EventRole.guest),
            viewerAttendeeId: 'me',
          ),
          isFalse,
        );
      });
    });
  });
}
