import 'package:events/events.dart';
import 'package:events/src/detail/event_poll.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// What the availability poll offers and lists (#507): whether it shows, who
/// may answer, which date leads and who the who-answered grid holds.
void main() {
  Event eventWith({
    EventStatus status = EventStatus.planning,
    EventSchedulingMode mode = EventSchedulingMode.poll,
  }) => item('e').event.copyWith(status: status, schedulingMode: mode);

  EventOccurrence date(
    String id, {
    OccurrenceStatus status = OccurrenceStatus.proposed,
    int sortOrder = 0,
  }) => confirmed(
    id,
    DateTime.utc(2026, 11, 1),
    sortOrder: sortOrder,
  ).copyWith(status: status);

  /// A roster row with an account, attending and a participant unless a test
  /// says otherwise. [account] false makes a guest who has none.
  EventAttendee attendee(
    String id, {
    EventRole? role = EventRole.participant,
    EventParticipationStatus status = EventParticipationStatus.attending,
    bool account = true,
  }) => EventAttendee(
    id: id,
    eventId: 'e',
    userId: account ? 'user-$id' : null,
    status: status,
    role: role,
    createdAt: kItemInstant,
    updatedAt: kItemInstant,
  );

  AvailabilityVoter voter(
    String attendeeId, {
    AvailabilityResponse response = AvailabilityResponse.available,
    bool eligible = true,
  }) => AvailabilityVoter(
    attendeeId: attendeeId,
    response: response,
    eligible: eligible,
  );

  OccurrenceAvailability tally(
    String occurrenceId, {
    int available = 0,
    int maybe = 0,
    int unavailable = 0,
    List<AvailabilityVoter> voters = const [],
  }) => OccurrenceAvailability(
    occurrenceId: occurrenceId,
    available: available,
    maybe: maybe,
    unavailable: unavailable,
    voters: voters,
  );

  AvailabilitySummary summaryOf(List<OccurrenceAvailability> tallies) =>
      AvailabilitySummary(occurrences: tallies);

  const noSummary = AvailabilitySummary(occurrences: []);

  List<String> ids(List<PollRow> rows) => [
    for (final row in rows) row.attendeeId,
  ];

  group('showsPoll', () {
    test('is true on a poll event with a proposed date', () {
      expect(showsPoll(eventWith(), [date('o1')]), true);
    });

    test('is true when another date is already confirmed', () {
      expect(
        showsPoll(eventWith(), [
          date('o1', status: OccurrenceStatus.confirmed),
          date('o2'),
        ]),
        true,
      );
    });

    for (final mode in [
      EventSchedulingMode.fixed,
      EventSchedulingMode.multiDay,
      EventSchedulingMode.unknown,
    ]) {
      test('is false on a ${mode.name} event', () {
        expect(showsPoll(eventWith(mode: mode), [date('o1')]), false);
      });
    }

    for (final status in [
      OccurrenceStatus.confirmed,
      OccurrenceStatus.declined,
      OccurrenceStatus.cancelled,
      OccurrenceStatus.unknown,
    ]) {
      test('is false on a poll event whose only date is ${status.name}', () {
        expect(showsPoll(eventWith(), [date('o1', status: status)]), false);
      });
    }

    test('is false on a poll event with no dates', () {
      expect(showsPoll(eventWith(), const []), false);
    });

    test('is false on an event of unknown status', () {
      expect(
        showsPoll(eventWith(status: EventStatus.unknown), [date('o1')]),
        false,
      );
    });

    test('still shows on a cancelled or archived event, to be read', () {
      // takesVotes is what closes the chips.
      for (final status in [EventStatus.cancelled, EventStatus.archived]) {
        expect(showsPoll(eventWith(status: status), [date('o1')]), true);
      }
    });
  });

  group('takesVotes', () {
    const allowed = {EventAction.voteAvailability};

    test('is true on a proposed date of a poll event', () {
      expect(takesVotes(eventWith(), date('o1'), allowed), true);
    });

    test('is true while the event is scheduled', () {
      final event = eventWith(status: EventStatus.scheduled);

      expect(takesVotes(event, date('o1'), allowed), true);
    });

    for (final status in [
      EventStatus.cancelled,
      EventStatus.archived,
      EventStatus.unknown,
    ]) {
      test('is false on a ${status.name} event', () {
        expect(
          takesVotes(eventWith(status: status), date('o1'), allowed),
          false,
        );
      });
    }

    for (final status in [
      OccurrenceStatus.confirmed,
      OccurrenceStatus.declined,
      OccurrenceStatus.cancelled,
      OccurrenceStatus.unknown,
    ]) {
      test('is false on a ${status.name} date', () {
        expect(
          takesVotes(eventWith(), date('o1', status: status), allowed),
          false,
        );
      });
    }

    test('is false without voteAvailability', () {
      expect(
        takesVotes(eventWith(), date('o1'), {
          EventAction.rsvp,
          EventAction.confirmDate,
        }),
        false,
      );
      expect(takesVotes(eventWith(), date('o1'), const {}), false);
    });

    for (final mode in [
      EventSchedulingMode.fixed,
      EventSchedulingMode.multiDay,
      EventSchedulingMode.unknown,
    ]) {
      test('is false on a proposed date of a ${mode.name} event', () {
        expect(takesVotes(eventWith(mode: mode), date('o1'), allowed), false);
      });
    }
  });

  group('votesIn', () {
    test('is the role table\'s voteAvailability', () {
      final who = [
        for (final role in EventRole.values)
          if (votesIn(eventWith(), role)) role,
      ];

      expect(who, [
        EventRole.host,
        EventRole.coHost,
        EventRole.organizer,
        EventRole.participant,
        EventRole.guest,
      ]);
    });

    test('is false for a role the server did not return', () {
      expect(votesIn(eventWith(), null), false);
    });

    test('is false on an event the server does not know yet', () {
      final local = eventWith().copyWith(isLocalOnly: true);

      expect(votesIn(local, EventRole.host), false);
    });
  });

  group('pollLeaders', () {
    final dates = [date('o1'), date('o2'), date('o3')];

    test('is the date with the most Available votes', () {
      final summary = summaryOf([
        tally('o1', available: 2),
        tally('o2', available: 3, unavailable: 4),
        tally('o3', available: 1),
      ]);

      expect(pollLeaders(dates, summary), {'o2'});
    });

    test('is the date with the fewest Unavailable when level on Available', () {
      final summary = summaryOf([
        tally('o1', available: 2, unavailable: 2),
        tally('o2', available: 2, unavailable: 1),
        tally('o3', available: 2, unavailable: 3),
      ]);

      expect(pollLeaders(dates, summary), {'o2'});
    });

    test('is every date level on both', () {
      final summary = summaryOf([
        tally('o1', available: 2, unavailable: 1, maybe: 3),
        tally('o2', available: 2, unavailable: 1),
        tally('o3', available: 2, unavailable: 2),
      ]);

      expect(pollLeaders(dates, summary), {'o1', 'o2'});
    });

    test('is none while no date has an Available vote', () {
      // A Maybe is not an Available, and an Unavailable lowers none.
      final summary = summaryOf([
        tally('o1', maybe: 4),
        tally('o2', unavailable: 2),
        tally('o3'),
      ]);

      expect(pollLeaders(dates, summary), isEmpty);
    });

    test('is none with no dates', () {
      expect(pollLeaders(const [], noSummary), isEmpty);
    });

    test('ignores a date that is not proposed, whatever it has', () {
      final summary = summaryOf([
        tally('o1', available: 1),
        tally('o2', available: 5),
        tally('o3', available: 4),
      ]);

      expect(
        pollLeaders([
          date('o1'),
          date('o2', status: OccurrenceStatus.declined),
          date('o3', status: OccurrenceStatus.confirmed),
        ], summary),
        {'o1'},
      );
    });

    test('ignores a proposed date the summary does not list', () {
      final summary = summaryOf([tally('o1', available: 1)]);

      expect(() => pollLeaders(dates, summary), returnsNormally);
      expect(pollLeaders(dates, summary), {'o1'});
    });

    test('ignores a summary entry for a date the cache does not hold', () {
      final summary = summaryOf([
        tally('o1', available: 1),
        tally('elsewhere', available: 9),
      ]);

      expect(() => pollLeaders(dates, summary), returnsNormally);
      expect(pollLeaders(dates, summary), {'o1'});
    });

    test('is none when the two lists share no date', () {
      final summary = summaryOf([tally('elsewhere', available: 9)]);

      expect(pollLeaders(dates, summary), isEmpty);
    });

    test('answers a set nothing can change', () {
      final summary = summaryOf([tally('o1', available: 1)]);

      expect(pollLeaders(dates, summary).clear, throwsUnsupportedError);
    });
  });

  group('pollRows', () {
    final event = eventWith();
    final polled = [date('o1'), date('o2', sortOrder: 1)];

    test('are the registered attendees whose role votes', () {
      final roster = [
        attendee('host', role: EventRole.host),
        attendee('coHost', role: EventRole.coHost),
        attendee('organizer', role: EventRole.organizer),
        attendee('participant'),
        attendee('guest', role: EventRole.guest),
      ];

      expect(ids(pollRows(event, polled, roster, noSummary)), [
        'host',
        'coHost',
        'organizer',
        'participant',
        'guest',
      ]);
    });

    test('hold the roster row of each', () {
      final roster = [attendee('a'), attendee('b')];

      final rows = pollRows(event, polled, roster, noSummary);

      expect(rows, [
        PollRow(attendeeId: 'a', attendee: roster[0]),
        PollRow(attendeeId: 'b', attendee: roster[1]),
      ]);
    });

    test('leave out a spectator and a guest without an account', () {
      final roster = [
        attendee('spectator', role: EventRole.spectator),
        attendee('visitor', role: EventRole.guest, account: false),
        attendee('participant'),
      ];

      expect(ids(pollRows(event, polled, roster, noSummary)), ['participant']);
    });

    test('leave out a moderator, and a role the server did not return', () {
      final roster = [
        attendee('moderator', role: EventRole.moderator),
        attendee('unnamed', role: null),
        attendee('unknown', role: EventRole.unknown),
      ];

      expect(pollRows(event, polled, roster, noSummary), isEmpty);
    });

    test('keep an attendee who has not answered the invitation', () {
      final roster = [
        attendee('invited', status: EventParticipationStatus.invited),
        attendee('maybe', status: EventParticipationStatus.maybe),
      ];

      expect(ids(pollRows(event, polled, roster, noSummary)), [
        'invited',
        'maybe',
      ]);
    });

    test('leave out a participant who answered Not attending', () {
      final roster = [
        attendee('out', status: EventParticipationStatus.notAttending),
        attendee('in'),
      ];

      expect(ids(pollRows(event, polled, roster, noSummary)), ['in']);
    });

    test('keep a participant who answered Not attending and voted', () {
      final out = attendee(
        'out',
        status: EventParticipationStatus.notAttending,
      );
      final summary = summaryOf([
        tally('o1', voters: [voter('out', eligible: false)]),
      ]);

      expect(pollRows(event, polled, [out], summary), [
        PollRow(attendeeId: 'out', attendee: out),
      ]);
    });

    test('hold a voter the roster does not, with no attendee', () {
      final summary = summaryOf([
        tally('o1', voters: [voter('stranger')]),
      ]);

      expect(pollRows(event, polled, const [], summary), [
        const PollRow(attendeeId: 'stranger'),
      ]);
    });

    test('hold a voter the roster leaves out, with the roster row', () {
      // A spectator who voted anyway: the server lists them, so the grid
      // does too.
      final spectator = attendee('spectator', role: EventRole.spectator);
      final summary = summaryOf([
        tally('o1', voters: [voter('spectator')]),
      ]);

      expect(pollRows(event, polled, [spectator], summary), [
        PollRow(attendeeId: 'spectator', attendee: spectator),
      ]);
    });

    test('list a voter once, however many dates they answered', () {
      final summary = summaryOf([
        tally('o1', voters: [voter('stranger'), voter('a')]),
        tally('o2', voters: [voter('a'), voter('stranger')]),
      ]);

      final rows = pollRows(event, polled, [attendee('a')], summary);

      expect(ids(rows), ['a', 'stranger']);
    });

    test("leave out a voter only on a date the grid doesn't show", () {
      final out = attendee(
        'out',
        status: EventParticipationStatus.notAttending,
      );
      final summary = summaryOf([
        tally('o1', voters: [voter('kept', eligible: false)]),
        tally('declined', voters: [voter('out', eligible: false)]),
        tally('uncached', voters: [voter('stranger')]),
      ]);
      final dates = [
        date('o1'),
        date('declined', status: OccurrenceStatus.declined),
      ];

      expect(ids(pollRows(event, dates, [out], summary)), ['kept']);
    });

    test('follow the roster, then the dates', () {
      final roster = [
        attendee('b'),
        attendee('a'),
        attendee('out', status: EventParticipationStatus.notAttending),
      ];
      final summary = summaryOf([
        tally('o1', voters: [voter('z'), voter('a'), voter('out')]),
        tally('o2', voters: [voter('y'), voter('z'), voter('b')]),
      ]);

      expect(ids(pollRows(event, polled, roster, summary)), [
        'b',
        'a',
        'z',
        'out',
        'y',
      ]);
    });

    test('are empty with no roster and no votes', () {
      expect(pollRows(event, polled, const [], noSummary), isEmpty);
    });
  });

  group('awaitingAnswer', () {
    final event = eventWith();
    final polled = [date('o1'), date('o2', sortOrder: 1)];

    List<PollRow> rowsOf(List<EventAttendee> roster) => [
      for (final a in roster) PollRow(attendeeId: a.id, attendee: a),
    ];

    test('counts the voting rows with no vote on the date', () {
      final roster = [attendee('a'), attendee('b'), attendee('c')];
      final summary = summaryOf([
        tally('o1', available: 1, voters: [voter('a')]),
      ]);

      expect(awaitingAnswer(event, rowsOf(roster), summary, 'o1'), 2);
    });

    test('counts nobody once everyone has answered', () {
      final roster = [attendee('a'), attendee('b')];
      final summary = summaryOf([
        tally(
          'o1',
          available: 1,
          maybe: 1,
          voters: [
            voter('a'),
            voter('b', response: AvailabilityResponse.maybe),
          ],
        ),
      ]);

      expect(awaitingAnswer(event, rowsOf(roster), summary, 'o1'), 0);
    });

    test('does not take a vote on another date for an answer', () {
      final roster = [attendee('a')];
      final summary = summaryOf([
        tally('o1', available: 1, voters: [voter('a')]),
        tally('o2'),
      ]);

      expect(awaitingAnswer(event, rowsOf(roster), summary, 'o2'), 1);
    });

    test('does not take a vote that does not count for an answer', () {
      final roster = [attendee('a')];
      final summary = summaryOf([
        tally('o1', voters: [voter('a', eligible: false)]),
      ]);

      expect(awaitingAnswer(event, rowsOf(roster), summary, 'o1'), 1);
    });

    test('counts every voting row on a date the summary does not list', () {
      final roster = [attendee('a'), attendee('b')];

      expect(awaitingAnswer(event, rowsOf(roster), noSummary, 'o1'), 2);
    });

    test('never counts a row with no attendee', () {
      const rows = [PollRow(attendeeId: 'stranger')];

      expect(awaitingAnswer(event, rows, noSummary, 'o1'), 0);
    });

    test('never counts someone not attending', () {
      final roster = [
        attendee('out', status: EventParticipationStatus.notAttending),
      ];

      expect(awaitingAnswer(event, rowsOf(roster), noSummary, 'o1'), 0);
    });

    test('never counts a row whose role cannot vote', () {
      // Such a row is in the grid only because the summary listed a vote.
      final roster = [
        attendee('spectator', role: EventRole.spectator),
        attendee('moderator', role: EventRole.moderator),
        attendee('unnamed', role: null),
      ];

      expect(awaitingAnswer(event, rowsOf(roster), noSummary, 'o1'), 0);
    });

    test('never counts a guest without an account', () {
      final roster = [
        attendee('visitor', role: EventRole.guest, account: false),
      ];

      expect(awaitingAnswer(event, rowsOf(roster), noSummary, 'o1'), 0);
    });

    test('counts the rows pollRows lists, none twice', () {
      final roster = [
        attendee('a'),
        attendee('b'),
        attendee('out', status: EventParticipationStatus.notAttending),
      ];
      final summary = summaryOf([
        tally(
          'o1',
          available: 1,
          voters: [voter('a'), voter('out', eligible: false), voter('who')],
        ),
        tally('o2', voters: [voter('who')]),
      ]);
      final rows = pollRows(event, polled, roster, summary);

      expect(awaitingAnswer(event, rows, summary, 'o1'), 1);
      expect(awaitingAnswer(event, rows, summary, 'o2'), 2);
    });
  });
}
