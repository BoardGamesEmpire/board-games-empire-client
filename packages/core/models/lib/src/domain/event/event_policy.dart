import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/event/game_addition_mode.dart';
import 'package:models/src/domain/event/interested_weight.dart';
import 'package:models/src/domain/event/occurrence_override_scope.dart';
import 'package:models/src/domain/event/vote_eligibility.dart';
import 'package:models/src/domain/event/vote_quorum_type.dart';
import 'package:models/src/domain/event/vote_threshold_type.dart';
import 'package:models/src/domain/game/platform_type.dart';

part 'event_policy.freezed.dart';

/// An event's rules: who can be invited and join, and how its game lineup is
/// built (#496).
///
/// One per event, read with it. A caller who may not read the policy is served
/// none, and so is an event that has none, so an `EventSnapshot` carries it as
/// nullable.
///
/// ## The allowed lists
///
/// [allowedCategoryIds], [allowedPlatformIds] and [allowedPlatformTypes] are
/// nullable because not every read carries them. Null means this read did not
/// carry the list, so it says nothing about what is allowed; it never means "no
/// restriction". An empty list is a list the read carried.
///
/// ## What is deliberately not here
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

    required bool restrictToGameCategories,
    required bool requireHostApprovalToJoin,
    required bool allowSpectators,
    required bool strictCapacity,
    required GameAdditionMode gameAdditionMode,
    required bool restrictToAttendeePool,
    required VoteThresholdType voteThresholdType,
    required VoteQuorumType voteQuorumType,
    required VoteEligibility voteEligibility,
    required InterestedWeight interestedWeight,
    required DateTime createdAt,
    required DateTime updatedAt,

    /// How far a date's own rules may depart from this policy. The server's
    /// column defaults to [OccurrenceOverrideScope.any].
    @Default(OccurrenceOverrideScope.any)
    OccurrenceOverrideScope occurrenceOverrideScope,

    /// The platform types a restriction allows. Null means this read did not
    /// carry the list, not that nothing is restricted.
    List<PlatformType>? allowedPlatformTypes,

    /// The platforms a restriction allows. Null means this read did not carry
    /// the list, not that nothing is restricted.
    List<String>? allowedPlatformIds,

    /// The categories [restrictToGameCategories] allows. Null means this read
    /// did not carry the list, not that nothing is restricted.
    List<String>? allowedCategoryIds,

    /// The most attendees the event takes. Null means no cap.
    int? maxAttendees,

    /// The most people the event takes, spectators included. Null means no
    /// cap.
    int? maxTotalParticipants,

    /// The longest a filler game may play, in minutes. Null means no fillers
    /// are permitted.
    int? fillerMaxPlayTime,

    /// What [voteThresholdType] needs, for the two types that take a number:
    /// the percentage a supermajority needs (66 for 66%), or the count a
    /// fixed-count threshold needs. Null for the others.
    int? voteThresholdValue,

    /// What [voteQuorumType] needs, for the two types that take a number: the
    /// percentage of eligible voters, or the count of votes. Null when there
    /// is no quorum.
    int? voteQuorumValue,

    /// How long a nomination stays open for votes, in hours. Null means the
    /// host closes it by hand.
    int? votingWindowHours,
  }) = _EventPolicy;
}
