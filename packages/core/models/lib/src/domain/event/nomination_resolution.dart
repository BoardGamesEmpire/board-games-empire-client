import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/event/nomination_status.dart';

part 'nomination_resolution.freezed.dart';

/// How a host's close of a vote came out (#518).
///
/// The server answers a resolve with it and stores none of it: a later read of
/// the nomination carries the [status] alone. It is read from the answer's
/// `resolution`, and the figures are the server's, never computed here.
@freezed
abstract class NominationResolution with _$NominationResolution {
  const factory NominationResolution({
    /// Where the vote ended: [NominationStatus.passed],
    /// [NominationStatus.failed] or [NominationStatus.quorumNotMet], or
    /// [NominationStatus.unknown] for a name this client does not know.
    required NominationStatus status,

    /// Read from `tally.forCount`.
    required int forCount,

    /// Read from `tally.againstCount`.
    required int againstCount,

    /// Read from `tally.interestedCount`.
    required int interestedCount,

    /// Read from `tally.totalVotes`.
    required int totalVotes,

    /// Whether enough of the eligible voters voted.
    required bool quorumMet,

    /// Whether the votes for reached the event's threshold.
    required bool thresholdMet,

    /// How many attendees the event's voter pool held.
    required int eligibleVoterCount,
  }) = _NominationResolution;
}
