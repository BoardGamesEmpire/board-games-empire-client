import 'package:events/events.dart';
import 'package:events/src/widgets/event_date_poll.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The poll on an event's dates as the dates section shows it (#507),
/// worked out from the poll's state, the cached event and the viewer's row.
void main() {
  const available = AvailabilityResponse.available;
  const maybe = AvailabilityResponse.maybe;

  final event = item('e').event
      .copyWith(schedulingMode: EventSchedulingMode.poll);

  EventOccurrence date(
    String id, {
    OccurrenceStatus status = OccurrenceStatus.proposed,
  }) => confirmed(id, DateTime.utc(2026, 11)).copyWith(status: status);

  EventAttendee attendee(
    String id, {
    EventRole role = EventRole.participant,
    EventParticipationStatus status = EventParticipationStatus.attending,
  }) => EventAttendee(
    id: id,
    eventId: 'e',
    userId: 'user-$id',
    status: status,
    role: role,
    createdAt: kItemInstant,
    updatedAt: kItemInstant,
  );

  final me = attendee('me');

  OccurrenceAvailability tally(
    String id,
    Map<String, AvailabilityResponse> by,
  ) => OccurrenceAvailability(
    occurrenceId: id,
    available: by.values.where((r) => r == available).length,
    maybe: by.values.where((r) => r == maybe).length,
    unavailable: 0,
    voters: [
      for (final MapEntry(key: attendeeId, value: response) in by.entries)
        AvailabilityVoter(
          attendeeId: attendeeId,
          response: response,
          eligible: true,
        ),
    ],
  );

  /// [datesPollView] for the participant `me` on [occurrences], with
  /// [roster] and [poll], and every callback offered.
  DatesPollView viewOf(
    List<EventOccurrence> occurrences, {
    List<EventAttendee>? roster,
    EventPollState poll = const EventPollState(),
    EventAttendee? viewer,
  }) {
    final shown = viewer ?? me;
    return datesPollView(
      snapshot: EventSnapshot(
        event: event,
        occurrences: occurrences,
        attendees: roster,
      ),
      viewer: shown,
      actions: eventActionsFor(event, eventRole: shown.role),
      poll: poll,
      onVote: (_, _) {},
      onRetry: () {},
      onWhoAnswered: () {},
    );
  }

  test('who has not answered shows only with a readable roster, on a date '
      'the summary lists, and never as nobody', () {
    final poll = EventPollState(
      load: EventPollLoad.loaded,
      summary: AvailabilitySummary(
        occurrences: [
          tally('o1', {'me': available}),
          tally('o2', {'me': available, 'a2': maybe}),
        ],
      ),
    );
    final dates = [date('o1'), date('o2'), date('o3')];
    final roster = [me, attendee('a2')];

    // o2 is answered by everyone, and o3 isn't listed.
    expect(viewOf(dates, roster: roster, poll: poll).awaiting, {'o1': 1});
    // Not read yet, or withheld.
    expect(viewOf(dates, poll: poll).awaiting, isEmpty);
    expect(viewOf(dates, roster: const [], poll: poll).awaiting, isEmpty);
  });

  test(
    'a summary that withholds the roster outranks a roster still cached',
    () {
      final poll = EventPollState(
        load: EventPollLoad.loaded,
        summary: AvailabilitySummary(
          occurrences: [tally('o1', {})],
          rosterVisible: false,
        ),
      );

      final view = viewOf(
        [date('o1')],
        roster: [me, attendee('a2')],
        poll: poll,
      );

      // Its empty voters say nothing of who answered, and Who answered would
      // only refuse.
      expect(view.awaiting, isEmpty);
      expect(view.onWhoAnswered, isNull);
    },
  );

  test('nobody is awaited on an event that takes no more answers', () {
    final poll = EventPollState(
      load: EventPollLoad.loaded,
      summary: AvailabilitySummary(
        occurrences: [
          tally('o1', {'me': available}),
        ],
      ),
    );
    final roster = [me, attendee('a2')];
    for (final status in [EventStatus.cancelled, EventStatus.archived]) {
      final view = datesPollView(
        snapshot: EventSnapshot(
          event: event.copyWith(status: status),
          occurrences: [date('o1')],
          attendees: roster,
        ),
        viewer: me,
        actions: eventActionsFor(event, eventRole: me.role),
        poll: poll,
        onVote: (_, _) {},
        onRetry: () {},
      );

      expect(view.awaiting, isEmpty, reason: '$status');
      expect(view.tallies.keys, ['o1'], reason: '$status');
    }
    expect(viewOf([date('o1')], roster: roster, poll: poll).awaiting, {
      'o1': 1,
    });
  });

  test("the chips wait for the viewer's own answers, and for a request", () {
    final summary = AvailabilitySummary(occurrences: [tally('o1', {})]);
    final dates = [date('o1')];

    // Not read yet, being read, failed, retried: nothing says what they gave.
    for (final poll in const [
      EventPollState(),
      EventPollState(load: EventPollLoad.loading),
      EventPollState(load: EventPollLoad.failed, refreshFailed: true),
      EventPollState(load: EventPollLoad.gone),
    ]) {
      expect(viewOf(dates, poll: poll).answersOpen, isFalse, reason: '$poll');
    }

    // Read, also while reading again or after a read that failed.
    for (final poll in [
      EventPollState(load: EventPollLoad.loaded, summary: summary),
      EventPollState(load: EventPollLoad.loading, summary: summary),
      EventPollState(
        load: EventPollLoad.failed,
        summary: summary,
        refreshFailed: true,
      ),
      // Refused: no read will ever tell them, and that needn't stop a vote.
      const EventPollState(load: EventPollLoad.hidden),
    ]) {
      expect(viewOf(dates, poll: poll).answersOpen, isTrue, reason: '$poll');
    }

    final acting = datesPollView(
      snapshot: EventSnapshot(event: event, occurrences: dates),
      viewer: me,
      actions: eventActionsFor(event, eventRole: me.role),
      poll: EventPollState(load: EventPollLoad.loaded, summary: summary),
      onVote: (_, _) {},
      onRetry: () {},
      acting: true,
    );
    expect(acting.answersOpen, isFalse);
  });

  test("the viewer's answer is the one being sent, else the summary's", () {
    final view = viewOf(
      [date('o1'), date('o2')],
      poll: EventPollState(
        load: EventPollLoad.loaded,
        summary: AvailabilitySummary(
          occurrences: [
            tally('o1', {'me': available}),
            tally('o2', {'me': available}),
          ],
        ),
        pending: const {'o2': maybe},
      ),
    );

    expect(view.answers, {'o1': available, 'o2': maybe});
  });

  test('each callback is offered only where it applies', () {
    final readable = [me, attendee('a2')];
    var view = viewOf([date('o1')], roster: readable);
    expect(view.onVote, isNotNull);
    expect(view.onWhoAnswered, isNotNull);
    expect(view.onRetry, isNull);

    // A spectator answers nothing, and the roster isn't read yet.
    view = viewOf([
      date('o1'),
    ], viewer: attendee('me', role: EventRole.spectator));
    expect(view.onVote, isNull);
    expect(view.canVoteOn, isNull);
    expect(view.onWhoAnswered, isNull);

    // Failed, and failed while the retry runs.
    view = viewOf(
      [date('o1')],
      poll: const EventPollState(
        load: EventPollLoad.loading,
        refreshFailed: true,
        refreshing: true,
      ),
    );
    expect(view.failed, isTrue);
    expect(view.retrying, isTrue);
    expect(view.onRetry, isNotNull);
  });
}
