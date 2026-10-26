import 'package:freezed_annotation/freezed_annotation.dart';

import '../common/reach.dart';
import 'event_scheduling_mode.dart';
import 'event_type.dart';
import 'game_addition_mode.dart';
import 'vote_quorum_type.dart';
import 'vote_threshold_type.dart';

part 'event_draft.freezed.dart';

/// What a person asked for when creating an event (#499): the backend's
/// create contract, less what this client doesn't send yet.
///
/// A null field is one the person did not set, so the server's default applies.
/// The queued create keeps the draft beside the local event, and the send turns
/// it into the request body.
@freezed
abstract class EventDraft with _$EventDraft {
  const EventDraft._();

  const factory EventDraft({
    required String title,

    /// The household the event joins. Null is an event outside any household.
    String? householdId,
    String? description,
    String? location,
    String? url,

    /// Null: the server's default.
    EventType? type,

    /// Null: the server's default.
    Reach? reach,
    @Default(EventSchedulingMode.fixed) EventSchedulingMode schedulingMode,

    /// In order: each one's position is the `sortOrder` the server is sent. A
    /// fixed event takes at most one.
    @Default(<EventOccurrenceDraft>[]) List<EventOccurrenceDraft> occurrences,
    EventPolicyDraft? policy,

    /// The users invited with the event, at most [maxInvitees].
    @Default(<String>[]) List<String> inviteUserIds,
  }) = _EventDraft;

  /// The server's ceiling on one create's `inviteUserIds`. A longer list is a
  /// 400.
  static const int maxInvitees = 50;

  /// Throws [ArgumentError], naming the field, for what no create can send:
  /// an empty [householdId], more than [maxInvitees] invitees, an `unknown`
  /// enum value anywhere in the draft, which has no wire name for the server
  /// to be sent, a vote threshold or quorum type sent without the value it
  /// takes, and a vote threshold, quorum or window below 1. Each is a 400,
  /// which is permanent and parks a queued create on its first attempt, so
  /// the caller hears of it before the draft is queued or sent.
  ///
  /// [url] is not checked: the server's `@IsUrl` is validator.js's `isURL`,
  /// whose rules this can't mirror without either passing what it refuses or
  /// refusing what it takes. The form that takes the url checks it.
  ///
  /// A caller adds its own checks to these.
  void checkSendable() {
    // The server's `@IsOptional` passes only null; an empty string meets its
    // `@IsNotEmpty`. Null is the event outside any household.
    if (householdId == '') {
      throw ArgumentError.value(
        householdId,
        'draft.householdId',
        'must not be empty (null is no household)',
      );
    }
    if (inviteUserIds.length > maxInvitees) {
      throw ArgumentError.value(
        inviteUserIds.length,
        'draft.inviteUserIds',
        'must hold at most $maxInvitees users (the server rejects more with a '
            '400)',
      );
    }

    void known<T extends Enum>(T? value, T unknown, String field) {
      if (value == unknown) {
        throw ArgumentError.value(
          value,
          field,
          'has no wire name, so the server cannot be sent it',
        );
      }
    }

    known(type, EventType.unknown, 'draft.type');
    known(reach, Reach.unknown, 'draft.reach');
    known(schedulingMode, EventSchedulingMode.unknown, 'draft.schedulingMode');
    if (policy case final policy?) {
      known(
        policy.gameAdditionMode,
        GameAdditionMode.unknown,
        'draft.policy.gameAdditionMode',
      );
      known(
        policy.voteThresholdType,
        VoteThresholdType.unknown,
        'draft.policy.voteThresholdType',
      );
      known(
        policy.voteQuorumType,
        VoteQuorumType.unknown,
        'draft.policy.voteQuorumType',
      );

      // The server reads a threshold or quorum value only for the types
      // that take one, and then requires it.
      void positive(int? value, String field, {required bool required}) {
        if (value == null ? required : value < 1) {
          throw ArgumentError.value(
            value,
            field,
            required
                ? 'must be at least 1 for this type'
                : 'must be at least 1',
          );
        }
      }

      if (policy.voteThresholdType
          case VoteThresholdType.supermajority ||
              VoteThresholdType.fixedCount) {
        positive(
          policy.voteThresholdValue,
          'draft.policy.voteThresholdValue',
          required: true,
        );
      }
      if (policy.voteQuorumType
          case VoteQuorumType.percentOfAttendees || VoteQuorumType.fixedCount) {
        positive(
          policy.voteQuorumValue,
          'draft.policy.voteQuorumValue',
          required: true,
        );
      }
      positive(
        policy.votingWindowHours,
        'draft.policy.votingWindowHours',
        required: false,
      );
    }
  }
}

/// One occurrence of an [EventDraft]: when it happens, and where if that
/// differs from the event's own place.
@freezed
abstract class EventOccurrenceDraft with _$EventOccurrenceDraft {
  const factory EventOccurrenceDraft({
    String? label,

    /// Null while the date is still to be set, as for an occurrence a poll
    /// proposes.
    DateTime? startDate,
    DateTime? endDate,
    String? location,
  }) = _EventOccurrenceDraft;
}

/// The rules the create form offers. Every other policy field takes the
/// server's default.
@freezed
abstract class EventPolicyDraft with _$EventPolicyDraft {
  const factory EventPolicyDraft({
    GameAdditionMode? gameAdditionMode,

    /// Only meaningful when [gameAdditionMode] is
    /// [GameAdditionMode.requiresVote].
    VoteThresholdType? voteThresholdType,

    /// Required by the server for [VoteThresholdType.supermajority] and
    /// [VoteThresholdType.fixedCount].
    int? voteThresholdValue,
    VoteQuorumType? voteQuorumType,

    /// Required by the server for [VoteQuorumType.percentOfAttendees] and
    /// [VoteQuorumType.fixedCount].
    int? voteQuorumValue,
    int? votingWindowHours,
  }) = _EventPolicyDraft;
}
