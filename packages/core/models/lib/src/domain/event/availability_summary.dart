import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/event/availability_response.dart';

part 'availability_summary.freezed.dart';

/// Where an event's dates stand in its availability poll: for each date, how
/// many people said they can come and who said what (#507).
///
/// Read whole from the server and never cached, so it is a picture of one
/// moment. A date of the event can be missing from it, and it can list a date
/// the cached event does not hold yet, so [of] answers null rather than
/// assuming the two agree.
///
/// ## What is deliberately not here
///
/// **`pendingVotes`, `participationRate`, `eligibleVoters` and the `attendees`
/// block's counts.** The server works them out from every registered attendee
/// who is still in the event, which includes spectators and moderators, who
/// cannot vote (backend#759). Shown as they are they would say people have yet
/// to answer who never can, so the types have no field for them. Who has yet
/// to answer is worked out from the roster the poll lists instead. All that is
/// kept of the block is [rosterVisible].
///
/// **A date's label, start, end and status.** The event already holds its
/// dates, and a date is matched to its tallies by its id, so a second copy
/// here could only disagree with it.
///
/// **`totalVotes`.** It is the three tallies added up.
@freezed
abstract class AvailabilitySummary with _$AvailabilitySummary {
  const factory AvailabilitySummary({
    /// Every date the server listed, of every status, in its order.
    required List<OccurrenceAvailability> occurrences,

    /// Whether the server lets this viewer read the event's roster: it counts
    /// any attendee at all. The roster's read and this count share one scope,
    /// and an event always has its host, so false is a withheld roster (#498),
    /// and true is one a detail read will bring if the cache lacks it yet.
    @Default(true) bool rosterVisible,
  }) = _AvailabilitySummary;
  const AvailabilitySummary._();

  /// The tallies for the date [occurrenceId], or null when the summary does
  /// not list it.
  OccurrenceAvailability? of(String occurrenceId) {
    for (final occurrence in occurrences) {
      if (occurrence.occurrenceId == occurrenceId) return occurrence;
    }
    return null;
  }
}

/// How one date of an event stands in its availability poll (#507).
///
/// [available], [maybe] and [unavailable] count only the votes that count: the
/// server leaves out a voter who is not attending, and lists that voter in
/// [voters] marked [AvailabilityVoter.eligible] false. So the three do not add
/// up to the length of [voters] when someone is marked out.
@freezed
abstract class OccurrenceAvailability with _$OccurrenceAvailability {
  const factory OccurrenceAvailability({
    /// The date these tallies are for.
    required String occurrenceId,
    required int available,
    required int maybe,
    required int unavailable,

    /// Every vote on the date, the ones that do not count included, in the
    /// server's order.
    required List<AvailabilityVoter> voters,
  }) = _OccurrenceAvailability;
}

/// One person's answer on one date, as the summary lists it (#507).
///
/// A voter is only a roster row, so the name to show comes from the event's
/// roster by [attendeeId].
@freezed
abstract class AvailabilityVoter with _$AvailabilityVoter {
  const factory AvailabilityVoter({
    /// The roster row of the person who answered.
    required String attendeeId,

    /// A name this client does not know reads as
    /// [AvailabilityResponse.unknown].
    required AvailabilityResponse response,

    /// Whether this answer is in the date's tallies. False for a voter who is
    /// not attending: the server keeps the vote and counts it again if they
    /// return.
    required bool eligible,
  }) = _AvailabilityVoter;
}
