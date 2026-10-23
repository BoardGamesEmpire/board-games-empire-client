import 'package:freezed_annotation/freezed_annotation.dart';

import 'game_addition_mode.dart';
import 'interested_weight.dart';
import 'vote_eligibility.dart';
import 'vote_quorum_type.dart';
import 'vote_threshold_type.dart';

part 'event_policy.freezed.dart';

/// An event's rules: who can be invited and join, and how its game lineup is
/// built (#496).
///
/// One per event, read with it. A caller who may not read the policy is served
/// none, and so is an event that has none, so an [EventSnapshot] carries it as
/// nullable.
///
/// ## What is deliberately not here
///
/// **The categories and platforms a restriction allows.** The server serves the
/// policy's own columns only, so [restrictToGameCategories] arrives as a flag
/// with no list behind it.
///
/// **Voting itself.** The `vote*` fields and [interestedWeight] are the rules a
/// vote is judged by. Nominations, votes and lineup games are out of scope for
/// the data layer (#496).
@freezed
abstract class EventPolicy with _$EventPolicy {
  const factory EventPolicy({
    required String id,
    required String eventId,
    required bool allowMemberInvites,
    required bool allowGuestInvites,

    /// The most attendees the event takes. Null means no cap.
    int? maxAttendees,
    required bool restrictToGameCategories,
    required bool requireHostApprovalToJoin,
    required bool allowSpectators,

    /// The most people the event takes, spectators included. Null means no
    /// cap.
    int? maxTotalParticipants,
    required bool strictCapacity,
    required GameAdditionMode gameAdditionMode,
    required bool restrictToAttendeePool,

    /// The longest a filler game may play, in minutes. Null means no fillers
    /// are permitted.
    int? fillerMaxPlayTime,
    required VoteThresholdType voteThresholdType,

    /// What [voteThresholdType] needs, for the two types that take a number: the
    /// percentage a supermajority needs (66 for 66%), or the count a fixed-count
    /// threshold needs. Null for the others.
    int? voteThresholdValue,
    required VoteQuorumType voteQuorumType,

    /// What [voteQuorumType] needs, for the two types that take a number: the
    /// percentage of eligible voters, or the count of votes. Null when there
    /// is no quorum.
    int? voteQuorumValue,
    required VoteEligibility voteEligibility,
    required InterestedWeight interestedWeight,

    /// How long a nomination stays open for votes, in hours. Null means the
    /// host closes it by hand.
    int? votingWindowHours,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _EventPolicy;
}
