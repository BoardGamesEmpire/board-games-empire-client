import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/event/game_addition_mode.dart';
import 'package:models/src/domain/event/interested_weight.dart';
import 'package:models/src/domain/event/vote_eligibility.dart';
import 'package:models/src/domain/event/vote_quorum_type.dart';
import 'package:models/src/domain/event/vote_threshold_type.dart';
import 'package:models/src/domain/game/platform_type.dart';

part 'event_occurrence_policy.freezed.dart';

/// One date's own rules, laid over its event's policy (#1009).
///
/// Every nullable field is an override: null means the date takes the event's
/// value. The lists and the `*Unrestricted` flags are not nullable; see each.
@freezed
abstract class EventOccurrencePolicy with _$EventOccurrencePolicy {
  const factory EventOccurrencePolicy({
    required String id,
    required String occurrenceId,

    /// The categories the date allows. Empty means the event's.
    required List<String> allowedCategoryIds,

    /// The platforms the date allows. Empty means the event's.
    required List<String> allowedPlatformIds,

    /// The platform types the date allows. Empty means the event's.
    required List<PlatformType> allowedPlatformTypes,

    /// True when the date lifts the event's platform-type restriction.
    required bool platformTypesUnrestricted,

    /// True when the date lifts the event's platform restriction.
    required bool platformsUnrestricted,

    /// True when the date lifts the event's capacity caps.
    required bool capacityUnrestricted,
    required DateTime createdAt,
    required DateTime updatedAt,
    bool? restrictToGameCategories,
    bool? strictCapacity,
    bool? requireHostApprovalToJoin,
    bool? allowSpectators,
    bool? restrictToAttendeePool,
    int? maxAttendees,
    int? maxTotalParticipants,
    int? fillerMaxPlayTime,
    int? voteThresholdValue,
    int? voteQuorumValue,
    int? votingWindowHours,
    GameAdditionMode? gameAdditionMode,
    VoteThresholdType? voteThresholdType,
    VoteQuorumType? voteQuorumType,
    VoteEligibility? voteEligibility,
    InterestedWeight? interestedWeight,
  }) = _EventOccurrencePolicy;
}
