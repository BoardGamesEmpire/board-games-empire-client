/// What the availability poll shows and lists, by the event's state and the
/// roster (#507).
///
/// The role table ([EventAction.voteAvailability]) knows who may vote, and
/// leaves the event's and the date's status to the screen: the server refuses
/// a vote on a date that isn't proposed, so the client offers only what it
/// will grant. These helpers narrow the table's answer by status, and work out
/// the leading date and the who-answered grid's rows from the cached event and
/// the summary the server returned.
///
/// The cached event and the summary can disagree: a date can be missing from
/// the summary, and the summary can list a date the cache doesn't hold. So
/// each helper reads only what both hold, and none throws.
library;

import 'package:equatable/equatable.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:models/domain.dart';

/// Whether the poll shows on [event], holding [occurrences] (#507): a Poll
/// event of known status with a Proposed date.
///
/// A cancelled or archived event still shows it, to be read. [takesVotes] is
/// what closes the answers.
bool showsPoll(Event event, List<EventOccurrence> occurrences) =>
    event.schedulingMode == EventSchedulingMode.poll &&
    event.status != EventStatus.unknown &&
    occurrences.any(
      (occurrence) => occurrence.status == OccurrenceStatus.proposed,
    );

/// Whether the viewer, allowed [allowed] (from eventActionsFor), may answer
/// for [occurrence] on [event] (#507): they hold voteAvailability, and the
/// date is a Proposed one of a Poll event that takes date writes.
bool takesVotes(
  Event event,
  EventOccurrence occurrence,
  Set<EventAction> allowed,
) =>
    allowed.contains(EventAction.voteAvailability) &&
    event.schedulingMode == EventSchedulingMode.poll &&
    takesDateWrites(event) &&
    occurrence.status == OccurrenceStatus.proposed;

/// Whether an attendee holding [role] on [event] may vote: the role table's
/// voteAvailability, so the table stays the one source.
bool votesIn(Event event, EventRole? role) => eventActionsFor(
  event,
  eventRole: role,
).contains(EventAction.voteAvailability);

/// The ids of the leading dates of [occurrences], by [summary] (#507): one id
/// is the leader, more are tied, none is no leader. Unmodifiable.
///
/// A Proposed date leads by the most Available votes, then the fewest
/// Unavailable. A date with no Available vote can't lead, and a Maybe counts
/// for nothing here. Only a date both lists hold is read.
Set<String> pollLeaders(
  List<EventOccurrence> occurrences,
  AvailabilitySummary summary,
) {
  final candidates = <OccurrenceAvailability>[
    for (final occurrence in occurrences)
      if (occurrence.status == OccurrenceStatus.proposed)
        if (summary.of(occurrence.id) case final tally?
            when tally.available > 0)
          tally,
  ];
  if (candidates.isEmpty) return const {};

  candidates.sort(_byLead);

  return Set.unmodifiable({
    for (final tally in candidates)
      if (_byLead(tally, candidates.first) == 0) tally.occurrenceId,
  });
}

/// Orders the more leading date first.
int _byLead(OccurrenceAvailability a, OccurrenceAvailability b) {
  final byAvailable = b.available.compareTo(a.available);
  return byAvailable != 0
      ? byAvailable
      : a.unavailable.compareTo(b.unavailable);
}

/// One row of the who-answered grid (#507): a person the poll lists.
final class PollRow extends Equatable {
  const PollRow({required this.attendeeId, this.attendee});

  /// The roster row's id, which the summary's voters carry.
  final String attendeeId;

  /// The row's person from the cached roster, for the name and the role. Null
  /// for a voter the roster doesn't hold: the summary names only the id, so
  /// nothing else is known about them.
  final EventAttendee? attendee;

  @override
  List<Object?> get props => [attendeeId, attendee];
}

/// The who-answered grid's rows, in roster order and then date order (#507):
/// every attendee of [roster] whose vote would count, then each voter on a
/// Proposed date of [occurrences] that the roster doesn't hold or leaves out.
/// Each person once.
///
/// A voter the roster leaves out, someone not attending say, still has a vote
/// the server lists, so the grid shows it, with the roster's row. A voter the
/// roster doesn't hold gets a row with no attendee. The summary lists every
/// date, but the grid's columns are the Proposed ones, so a vote only on some
/// other date would be a row of dashes, reading as someone who ignored the
/// poll.
List<PollRow> pollRows(
  Event event,
  List<EventOccurrence> occurrences,
  List<EventAttendee> roster,
  AvailabilitySummary summary,
) {
  final rows = <PollRow>[];
  final listed = <String>{};

  for (final attendee in roster) {
    if (_voteWouldCount(event, attendee) && listed.add(attendee.id)) {
      rows.add(PollRow(attendeeId: attendee.id, attendee: attendee));
    }
  }

  final byId = {for (final attendee in roster) attendee.id: attendee};
  for (final occurrence in occurrences) {
    if (occurrence.status != OccurrenceStatus.proposed) continue;
    final voters = summary.of(occurrence.id)?.voters;
    for (final voter in voters ?? const <AvailabilityVoter>[]) {
      if (listed.add(voter.attendeeId)) {
        rows.add(
          PollRow(
            attendeeId: voter.attendeeId,
            attendee: byId[voter.attendeeId],
          ),
        );
      }
    }
  }

  return rows;
}

/// How many of [rows] whose votes would count have no counted vote on the
/// date [occurrenceId] (#507).
///
/// A row with no attendee never counts, because nothing is known about them,
/// and neither does one whose vote wouldn't count. A vote the server marks
/// ineligible isn't an answer, so its voter still awaits one. A date the
/// summary doesn't list has no votes, so every such row awaits.
int awaitingAnswer(
  Event event,
  List<PollRow> rows,
  AvailabilitySummary summary,
  String occurrenceId,
) {
  final answered = {
    for (final voter
        in summary.of(occurrenceId)?.voters ?? const <AvailabilityVoter>[])
      if (voter.eligible) voter.attendeeId,
  };

  return rows.where((row) {
    final attendee = row.attendee;

    return attendee != null &&
        _voteWouldCount(event, attendee) &&
        !answered.contains(row.attendeeId);
  }).length;
}

/// Whether a vote by [attendee] would count: they have an account, which a
/// vote is bound to, a role that votes, and no answer of Not attending.
bool _voteWouldCount(Event event, EventAttendee attendee) =>
    attendee.userId != null &&
    attendee.status != EventParticipationStatus.notAttending &&
    votesIn(event, attendee.role);
