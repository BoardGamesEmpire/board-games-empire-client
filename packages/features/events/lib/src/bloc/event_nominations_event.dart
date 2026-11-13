import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:models/domain.dart';

/// Input to the nominations on an event's Games tab (#517), the host's
/// decisions among it (#518).
///
/// Each names the event by the id the screen shows, which a reconcile can
/// move while it is open (#499), so the id travels with the request rather
/// than with the bloc.
sealed class EventNominationsEvent extends Equatable {
  const EventNominationsEvent();

  @override
  List<Object?> get props => [];
}

/// Read every nomination of the event [eventId]: when the tab opens, and
/// after each detail read. The viewer's own writes change their rows as they
/// end, and read only where the answer leaves a row unsettled. A retry is
/// [EventNominationsRetryRequested].
final class EventNominationsRequested extends EventNominationsEvent {
  const EventNominationsRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The person asked to read the nominations again, after a read failed. Read
/// as [EventNominationsRequested] is, and the state says so while it runs
/// (`EventNominationsState.refreshing`).
final class EventNominationsRetryRequested extends EventNominationsEvent {
  const EventNominationsRetryRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The viewer nominates [game], a row of the event [eventId]'s pool, for the
/// whole event or, with [occurrenceId], for one date.
final class GameNominated extends EventNominationsEvent {
  const GameNominated(this.eventId, this.game, {this.occurrenceId});

  final String eventId;
  final OfferedGame game;
  final String? occurrenceId;

  @override
  List<Object?> get props => [eventId, game, occurrenceId];
}

/// The viewer votes [voteType] on [nomination] of the event [eventId], with
/// [comment] when they added a note.
final class NominationVoteCast extends EventNominationsEvent {
  const NominationVoteCast(
    this.eventId,
    this.nomination,
    this.voteType, {
    this.comment,
  });

  final String eventId;
  final EventNomination nomination;
  final VoteType voteType;
  final String? comment;

  @override
  List<Object?> get props => [eventId, nomination, voteType, comment];
}

/// The viewer withdraws their own [nomination] of the event [eventId].
final class NominationWithdrawn extends EventNominationsEvent {
  const NominationWithdrawn(this.eventId, this.nomination);

  final String eventId;
  final EventNomination nomination;

  @override
  List<Object?> get props => [eventId, nomination];
}

/// The host approves [nomination] of the event [eventId], which awaits
/// approval, so its game joins the lineup (#518).
final class NominationApproved extends EventNominationsEvent {
  const NominationApproved(this.eventId, this.nomination);

  final String eventId;
  final EventNomination nomination;

  @override
  List<Object?> get props => [eventId, nomination];
}

/// The host rejects [nomination] of the event [eventId], which awaits
/// approval (#518).
final class NominationRejected extends EventNominationsEvent {
  const NominationRejected(this.eventId, this.nomination);

  final String eventId;
  final EventNomination nomination;

  @override
  List<Object?> get props => [eventId, nomination];
}

/// The host closes the vote on [nomination] of the event [eventId], which is
/// open, for the server to count and settle (#518).
final class NominationResolved extends EventNominationsEvent {
  const NominationResolved(this.eventId, this.nomination);

  final String eventId;
  final EventNomination nomination;

  @override
  List<Object?> get props => [eventId, nomination];
}

/// A [write] the screen's own re-check stopped before it was sent, of the
/// game titled [title]. Nothing is sent: the outcome says so, since a screen
/// reader hears nothing happen when a press sends nothing.
final class NominationWriteDropped extends EventNominationsEvent {
  const NominationWriteDropped(
    this.write, {
    required this.title,
    this.subtitle,
  });

  final NominationWrite write;
  final String title;

  /// A nominate's pool row's subtitle, where it has one (#851), which its
  /// outcome names the game with. Every other write's outcome names the
  /// nomination's title alone, so it is ignored there.
  final String? subtitle;

  @override
  List<Object?> get props => [write, title, subtitle];
}

/// The person closed the last write's banner.
final class EventNominationsOutcomeDismissed extends EventNominationsEvent {
  const EventNominationsOutcomeDismissed();
}
