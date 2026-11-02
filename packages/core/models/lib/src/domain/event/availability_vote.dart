import 'package:freezed_annotation/freezed_annotation.dart';

import 'availability_response.dart';

part 'availability_vote.freezed.dart';

/// One availability vote, as the server returns it when the caller casts it
/// (#507): who answered which date, and what they said.
///
/// A vote is the bare row, so it carries no mark for whether it counts. That
/// mark comes with the summary, on [AvailabilityVoter.eligible]. A caller who
/// votes again on a date changes this row rather than adding another, so
/// [updatedAt] moves and [id] does not.
@freezed
abstract class AvailabilityVote with _$AvailabilityVote {
  const factory AvailabilityVote({
    required String id,

    /// The date this vote answers.
    required String occurrenceId,

    /// The roster row of the person who voted.
    required String attendeeId,
    required AvailabilityResponse response,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _AvailabilityVote;
}
