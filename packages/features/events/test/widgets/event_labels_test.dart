import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

/// The words for each of an event's enums (#498), and none for a value this
/// client can't read: a newer server's value is not a guess at one.
void main() {
  final l10n = lookupEventsLocalizations(const Locale('en'));

  /// Checks that [label] gives each value in [expected] its words, and that
  /// it covers every value but `unknown`, which gets none.
  void names<T extends Enum>(
    List<T> values,
    String? Function(EventsLocalizations l10n, T value) label,
    Map<T, String> expected,
  ) {
    for (final value in values) {
      expect(
        label(l10n, value),
        value.name == 'unknown' ? isNull : expected[value],
        reason: '$value',
      );
    }
    expect(expected, hasLength(values.length - 1));
  }

  test('names each type', () {
    names(EventType.values, eventTypeLabel, {
      EventType.adultsOnly: 'Adults only',
      EventType.casualGathering: 'Casual gathering',
      EventType.competitivePlay: 'Competitive play',
      EventType.familyNight: 'Family night',
      EventType.kidFriendly: 'Kid friendly',
      EventType.learningSession: 'Learning session',
      EventType.longGameDay: 'Long game day',
      EventType.mixedAges: 'Mixed ages',
      EventType.partyGames: 'Party games',
      EventType.strategyNight: 'Strategy night',
    });
  });

  test('names each status', () {
    names(EventStatus.values, eventStatusLabel, {
      EventStatus.archived: 'Archived',
      EventStatus.cancelled: 'Cancelled',
      EventStatus.completed: 'Completed',
      EventStatus.ongoing: 'Happening now',
      EventStatus.planning: 'Planning',
      EventStatus.scheduled: 'Scheduled',
    });
  });

  test('names each reach', () {
    names(Reach.values, eventReachLabel, {
      Reach.friends: 'Friends',
      Reach.friendsOfFriends: 'Friends of friends',
      Reach.private: 'Private',
      Reach.public: 'Public',
    });
  });

  test('names each role, in a sentence and on the roster', () {
    names(EventRole.values, eventRolePhrase, {
      EventRole.host: 'the host',
      EventRole.coHost: 'a co-host',
      EventRole.organizer: 'an organizer',
      EventRole.moderator: 'a moderator',
      EventRole.participant: 'a participant',
      EventRole.guest: 'a guest',
      EventRole.spectator: 'a spectator',
    });
    names(EventRole.values, eventRoleLabel, {
      EventRole.host: 'Host',
      EventRole.coHost: 'Co-host',
      EventRole.organizer: 'Organizer',
      EventRole.moderator: 'Moderator',
      EventRole.participant: 'Participant',
      EventRole.guest: 'Guest',
      EventRole.spectator: 'Spectator',
    });
  });

  test("names each date's status", () {
    names(OccurrenceStatus.values, occurrenceStatusLabel, {
      OccurrenceStatus.proposed: 'Proposed',
      OccurrenceStatus.confirmed: 'Confirmed',
      OccurrenceStatus.declined: 'Declined',
      OccurrenceStatus.cancelled: 'Cancelled',
    });
  });

  test('names each answer, and none where there is none', () {
    names(EventParticipationStatus.values, eventRsvpLabel, {
      EventParticipationStatus.attending: 'Going',
      EventParticipationStatus.invited: 'Invited',
      EventParticipationStatus.maybe: 'Maybe',
      EventParticipationStatus.notAttending: 'Not going',
    });
    expect(eventRsvpLabel(l10n, null), isNull);
  });

  testWidgets("a date's name is its label, else its when, else none yet", (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en', 'US'),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    // Local, as the pickers give it: Monday 26 October 2026, 6 PM.
    final now = DateTime(2026, 10, 26, 18);
    final start = DateTime(2026, 11, 6, 19, 30);
    final date = confirmed('o-1', start);

    expect(
      eventDateName(context, date.copyWith(label: ' Day 1 '), now: now),
      'Day 1',
    );
    expect(
      eventDateName(context, date.copyWith(label: '  '), now: now),
      'Fri, Nov 6 · 7:30 PM',
    );
    expect(
      eventDateName(context, date.copyWith(startDate: null), now: now),
      'No date yet',
    );
  });
}
