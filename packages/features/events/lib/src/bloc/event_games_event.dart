import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:models/domain.dart';

/// Input to the games pool on an event's Games tab (#516).
///
/// Each names the event by the id the screen shows, which a reconcile can
/// move while it is open (#499), so the id travels with the request rather
/// than with the bloc. So do the attendees whose offered games a read of the
/// pool is for (#851): null for every attendee's, and otherwise a list that
/// narrows the read to those attendees, as the viewer's own row where the
/// roster is withheld or not read yet.
sealed class EventGamesEvent extends Equatable {
  const EventGamesEvent();

  @override
  List<Object?> get props => [];
}

/// Read the games offered for the event [eventId], every attendee's or, when
/// [attendeeIds] is a list, those attendees': when the tab opens, and after
/// each detail read. The bloc reads it again itself once an offer run ends,
/// and once a take-back ends unless it failed, but not while the event is
/// gone and no read is out; a dropped write reads nothing. A retry is
/// [EventGamesRetryRequested].
final class EventGamesRequested extends EventGamesEvent {
  const EventGamesRequested(this.eventId, this.attendeeIds);

  final String eventId;
  final List<String>? attendeeIds;

  @override
  List<Object?> get props => [eventId, attendeeIds];
}

/// The person asked to read the pool again, after a read failed. Read as
/// [EventGamesRequested] is, and the state says so while it runs
/// (`EventGamesState.refreshing`).
final class EventGamesRetryRequested extends EventGamesEvent {
  const EventGamesRetryRequested(this.eventId, this.attendeeIds);

  final String eventId;
  final List<String>? attendeeIds;

  @override
  List<Object?> get props => [eventId, attendeeIds];
}

/// The viewer, the attendee [attendeeId] of the event [eventId], offers the
/// games [picks] from their collection, sent in order in batches of up to
/// 100 (#851). The pool is read again once the run ends, for [attendeeIds]
/// or for the attendees a request named since, unless the event is gone and
/// no read is out.
final class EventGamesOffered extends EventGamesEvent {
  const EventGamesOffered(
    this.eventId,
    this.attendeeId,
    this.picks, {
    required this.attendeeIds,
  });

  final String eventId;
  final String attendeeId;
  final List<OfferPick> picks;
  final List<String>? attendeeIds;

  @override
  List<Object?> get props => [eventId, attendeeId, picks, attendeeIds];
}

/// The attendee [attendeeId] of the event [eventId] takes [game] back off the
/// pool. The pool is read again once the server answers, unless the
/// take-back failed or the event is gone and no read is out, for
/// [attendeeIds] or for the attendees a request named since.
final class EventGameTakenBack extends EventGamesEvent {
  const EventGameTakenBack(
    this.eventId,
    this.attendeeId,
    this.game, {
    required this.attendeeIds,
  });

  final String eventId;
  final String attendeeId;
  final OfferedGame game;
  final List<String>? attendeeIds;

  @override
  List<Object?> get props => [eventId, attendeeId, game, attendeeIds];
}

/// A [write] the screen's own re-check stopped before it was sent, of the
/// game titled [title], with its [subtitle] where it has one (#851), when
/// there is one. Nothing is sent: the outcome says so, since a screen reader
/// hears nothing happen when a press sends nothing.
final class EventGamesWriteDropped extends EventGamesEvent {
  const EventGamesWriteDropped(this.write, {this.title, this.subtitle});

  final EventGamesWrite write;
  final String? title;
  final String? subtitle;

  @override
  List<Object?> get props => [write, title, subtitle];
}

/// The person closed the last write's banner.
final class EventGamesOutcomeDismissed extends EventGamesEvent {
  const EventGamesOutcomeDismissed();
}
