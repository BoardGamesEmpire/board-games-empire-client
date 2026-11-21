import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:models/domain.dart';

/// Input to an event's lineup (#519).
///
/// Each names the event by the id the screen shows, which a reconcile can
/// move while it is open (#499), so the id travels with the request rather
/// than with the bloc.
sealed class EventLineupEvent extends Equatable {
  const EventLineupEvent();

  @override
  List<Object?> get props => [];
}

/// Read the lineup of the event [eventId]: when the screen opens, and after
/// each detail read. A retry is [EventLineupRetryRequested].
final class EventLineupRequested extends EventLineupEvent {
  const EventLineupRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The person asked to read the lineup again, after a read failed. Read as
/// [EventLineupRequested] is, and the state says so while it runs
/// (`EventLineupState.refreshing`).
final class EventLineupRetryRequested extends EventLineupEvent {
  const EventLineupRetryRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// A host adds [game], a row of the event [eventId]'s pool, straight to the
/// lineup, with no nomination (#519): to the whole event, or with
/// [occurrenceId] to one date, in [role], with [notes]. [maxPlayTime] is for a
/// filler: the remote drops it from any other role.
final class LineupGameAdded extends EventLineupEvent {
  const LineupGameAdded(
    this.eventId,
    this.game, {
    this.occurrenceId,
    this.role = ScheduledGameRole.primary,
    this.notes,
    this.maxPlayTime,
  });

  final String eventId;
  final OfferedGame game;
  final String? occurrenceId;
  final ScheduledGameRole role;
  final String? notes;
  final int? maxPlayTime;

  @override
  List<Object?> get props => [
    eventId,
    game,
    occurrenceId,
    role,
    notes,
    maxPlayTime,
  ];
}

/// A host takes [game] out of the lineup of the event [eventId] (#520).
final class LineupGameRemoved extends EventLineupEvent {
  const LineupGameRemoved(this.eventId, this.game);

  final String eventId;
  final LineupGame game;

  @override
  List<Object?> get props => [eventId, game];
}

/// A [write] the screen's own re-check stopped before it was sent, of the
/// game titled [title]. Nothing is sent: the outcome says so, since a screen
/// reader hears nothing happen when a press sends nothing.
final class LineupWriteDropped extends EventLineupEvent {
  const LineupWriteDropped(this.write, {required this.title, this.subtitle});

  final LineupWrite write;
  final String title;

  /// The game's subtitle, where it has one (#920).
  final String? subtitle;

  @override
  List<Object?> get props => [write, title, subtitle];
}

/// The person closed the last write's banner.
final class EventLineupOutcomeDismissed extends EventLineupEvent {
  const EventLineupOutcomeDismissed();
}
