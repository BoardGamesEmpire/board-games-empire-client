import 'package:events/src/bloc/event_detail_state.dart';
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

/// The date a [NominationScope] names.
extension NominationScopeDate on NominationScope {
  /// The date this scope names, or null for the whole event: what a choice
  /// is checked by ([scopeMode], #1070) and sent for.
  String? get occurrenceId => switch (this) {
    WholeEventScope() => null,
    DateScope(:final occurrenceId) => occurrenceId,
  };
}

/// The per-choice check Nominate and the direct add share (#1070): which of
/// [scopes], what a control offers in [view] on [detail], it is offered
/// for, by whether [open] says the control is offered under the mode it is
/// checked by. Null where none is.
///
/// Under a view there is one scope, the view's, so the view's mode decides
/// ([viewMode]): all of [scopes] where the control is offered under it, and
/// null where it isn't or while the mode is unknown, its date's policy
/// still to come from a read (#1063). With no view each choice is checked
/// under its own scope's mode ([scopeMode]): the whole event under the
/// event's, a date under its own, and left out while that is unknown.
List<NominateScope>? openChoicesIn(
  EventDetailReady detail, {
  required GamesDateView? view,
  required List<NominateScope> scopes,
  required bool Function(GameAdditionMode mode) open,
}) {
  // Not passed on unknown: the gates take a null mode as the event's.
  bool offered(GameAdditionMode? mode) => mode != null && open(mode);
  if (view != null) return offered(viewMode(detail, view)) ? scopes : null;
  final choices = [
    for (final choice in scopes)
      if (offered(scopeMode(detail, choice.scope.occurrenceId))) choice,
  ];
  return choices.isEmpty ? null : choices;
}

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
