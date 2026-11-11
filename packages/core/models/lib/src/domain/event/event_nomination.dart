import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/event/nomination_status.dart';
import 'package:models/src/domain/event/vote_type.dart';

part 'event_nomination.freezed.dart';

/// One attendee's vote on a nomination (#517).
@freezed
abstract class EventNominationVote with _$EventNominationVote {
  const factory EventNominationVote({
    required String id,

    /// The roster row of the attendee who voted.
    required String attendeeId,
    required VoteType voteType,

    /// Whether the vote counts toward the tally. The server marks a vote
    /// ineligible when the voter falls outside the event's voter pool; it is
    /// still shown, but only eligible votes are counted.
    required bool eligible,

    /// What the voter said with the vote, or null when they said nothing.
    String? comment,
  }) = _EventNominationVote;
}

/// A game nominated for an event's lineup, with the votes cast on it (#517).
///
/// It carries no priority: the lineup has no ordering a nomination could
/// claim (#517). It names no supplier attendee either, only [suppliedFromId];
/// the server does not serve the supplier's roster id on a nomination
/// (backend#1213), and the offered game it points at names the owner.
@freezed
abstract class EventNomination with _$EventNomination {
  const factory EventNomination({
    required String id,
    required String eventId,
    required String platformGameId,

    /// Read from `platformGame.game.id`.
    required String gameId,

    /// Read from `platformGame.game.title`.
    required String title,

    /// Read from `platformGame.platform.name`.
    required String platformName,
    required NominationStatus status,

    /// The roster row of the attendee who nominated the game.
    required String nominatedById,

    /// The `OfferedGame.id` the nominated copy is supplied from.
    required String suppliedFromId,
    required DateTime createdAt,

    /// The occurrence the nomination is for, or null for the whole event.
    String? occurrenceId,

    /// Read from `platformGame.game.thumbnail`; null when the game has none.
    String? thumbnail,

    /// The status a paused nomination returns to, or null when it is not
    /// paused.
    NominationStatus? pausedFrom,

    /// When voting closes, or null when it has no deadline. Voting is never
    /// disabled by it on the client.
    DateTime? votingDeadline,

    /// Read from `nominatedBy.user.username`; null when the server did not
    /// say.
    String? nominatedByUsername,
    @Default(<EventNominationVote>[]) List<EventNominationVote> votes,
  }) = _EventNomination;
}
