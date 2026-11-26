import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/detail/games_date_view.dart';
import 'package:models/domain.dart';

/// One choice Nominate offers (#517): the scope it nominates for, and the
/// date it names, or null for the whole event.
typedef NominateScope = ({NominationScope scope, EventOccurrence? date});

/// What Nominate offers on [detail] as of [now] (#517), in [view], the row
/// of dates' choice (#1042), from which a nomination takes its scope: under
/// one date, that date, while a game can still be nominated for it
/// ([nominatableDates]), and nothing once it can't; under Every date, the
/// whole event. With no view, as on an event with no row, the whole event
/// (#1062): the row is there on every event of more than one date, so a
/// choice of dates is never left to ask. Nominate nominates for the one
/// choice; with none, it isn't offered.
List<NominateScope> nominateScopes(
  EventDetail detail, {
  required DateTime now,
  GamesDateView? view,
}) => switch (view) {
  OneDateView(:final occurrenceId) => [
    for (final date in nominatableDates(detail, now: now))
      if (date.id == occurrenceId) (scope: DateScope(date.id), date: date),
  ],
  EveryDateView() || null => const [(scope: WholeEventScope(), date: null)],
};

/// Whether whoever brings [game] has answered Not going (#517), which the
/// server refuses a nomination for: the viewer, by their own answer on
/// [detail], as Offer games reads it; anyone else by their row on the
/// roster. Where the roster is withheld the pool holds only the viewer's own
/// games, so their answer decides.
bool supplierNotGoing(EventDetail detail, OfferedGame game) {
  final viewer = detail.attendance;
  final supplier = viewer != null && viewer.id == game.attendeeId
      ? viewer
      : detail.snapshot.attendees
            ?.where((row) => row.id == game.attendeeId)
            .firstOrNull;
  return supplier?.status == EventParticipationStatus.notAttending;
}
