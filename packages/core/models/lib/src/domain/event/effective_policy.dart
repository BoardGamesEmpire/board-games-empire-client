import 'package:models/src/domain/event/event_occurrence_policy.dart';
import 'package:models/src/domain/event/event_policy.dart';
import 'package:models/src/domain/event/event_snapshot.dart';
import 'package:models/src/domain/event/game_addition_mode.dart';
import 'package:models/src/domain/event/interested_weight.dart';
import 'package:models/src/domain/event/vote_eligibility.dart';
import 'package:models/src/domain/event/vote_quorum_type.dart';
import 'package:models/src/domain/event/vote_threshold_type.dart';

/// The rules a game addition on one date is held to (#1009).
typedef EffectiveGamePolicy = ({
  GameAdditionMode gameAdditionMode,
  VoteThresholdType voteThresholdType,
  int? voteThresholdValue,
  VoteQuorumType voteQuorumType,
  int? voteQuorumValue,
  VoteEligibility voteEligibility,
  InterestedWeight interestedWeight,
  int? votingWindowHours,
});

/// A date's effective game policy: the date's value for each field it sets,
/// else the event's, else the server's default.
///
/// Mirrors the backend's `foldPolicy`, so the client and the server judge a
/// nomination by the same rules. [event] and [date] may each be null.
EffectiveGamePolicy effectiveGamePolicy(
  EventPolicy? event,
  EventOccurrencePolicy? date,
) => (
  gameAdditionMode:
      date?.gameAdditionMode ??
      event?.gameAdditionMode ??
      GameAdditionMode.direct,
  voteThresholdType:
      date?.voteThresholdType ??
      event?.voteThresholdType ??
      VoteThresholdType.simpleMajority,
  voteThresholdValue: date?.voteThresholdValue ?? event?.voteThresholdValue,
  voteQuorumType:
      date?.voteQuorumType ?? event?.voteQuorumType ?? VoteQuorumType.none,
  voteQuorumValue: date?.voteQuorumValue ?? event?.voteQuorumValue,
  voteEligibility:
      date?.voteEligibility ??
      event?.voteEligibility ??
      VoteEligibility.confirmedOnly,
  interestedWeight:
      date?.interestedWeight ??
      event?.interestedWeight ??
      InterestedWeight.asAbstain,
  votingWindowHours: date?.votingWindowHours ?? event?.votingWindowHours,
);

extension EventSnapshotGamePolicy on EventSnapshot {
  /// The game policy for one date, or for the whole event when
  /// [occurrenceId] is null.
  ///
  /// A date with no override in [occurrencePolicies], or a read that carried
  /// none, takes the event's policy.
  EffectiveGamePolicy gamePolicyFor(String? occurrenceId) {
    EventOccurrencePolicy? date;
    if (occurrenceId != null) {
      for (final candidate
          in occurrencePolicies ?? const <EventOccurrencePolicy>[]) {
        if (candidate.occurrenceId == occurrenceId) {
          date = candidate;
          break;
        }
      }
    }
    return effectiveGamePolicy(policy, date);
  }
}
