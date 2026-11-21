/// The lineup on an event's Games tab (#519): its games grouped by the date
/// each is on, and as the row of dates' choice shows them (#1042).
library;

import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:events/src/detail/event_status_now.dart';
import 'package:events/src/detail/games_date_view.dart';
import 'package:models/domain.dart';

/// What a group of the lineup's games is for.
enum LineupGroupKind {
  /// The event's own games, which cover every date.
  everyDate,

  /// One of the event's dates.
  date,

  /// The dates the event no longer lists: one removed since the game was
  /// added (backend#1310), or one the viewer can't read.
  goneDate,
}

/// One group of the lineup's games: what it is for, the date where it is
/// one, and its games in the server's order.
typedef LineupGroup = ({
  LineupGroupKind kind,
  EventOccurrence? date,
  List<LineupGame> games,
});

/// [games] grouped by the date each is on, among the event's [occurrences]
/// (#519): the event's own games first, then each date that has games, in
/// the event's order of them (their `sortOrder`, then their id), then one
/// group for every game whose date isn't among [occurrences]. A game is in
/// exactly one group, so none is dropped. A group with no games is left
/// out, and each keeps the server's order of its games.
List<LineupGroup> lineupGroups(
  List<LineupGame> games,
  List<EventOccurrence> occurrences,
) {
  final known = {for (final date in occurrences) date.id};
  final own = <LineupGame>[];
  final byDate = <String, List<LineupGame>>{};
  final gone = <LineupGame>[];
  for (final game in games) {
    switch (game.occurrenceId) {
      case null:
        own.add(game);
      case final id when known.contains(id):
        byDate.putIfAbsent(id, () => []).add(game);
      case _:
        gone.add(game);
    }
  }
  final dates = [...occurrences]
    ..sort(
      (a, b) => a.sortOrder != b.sortOrder
          ? a.sortOrder.compareTo(b.sortOrder)
          : a.id.compareTo(b.id),
    );

  return [
    if (own.isNotEmpty)
      (kind: LineupGroupKind.everyDate, date: null, games: own),
    for (final date in dates)
      if (byDate[date.id] case final dated?)
        (kind: LineupGroupKind.date, date: date, games: dated),
    if (gone.isNotEmpty)
      (kind: LineupGroupKind.goneDate, date: null, games: gone),
  ];
}

/// [games] as the Lineup sub-tab shows them in [view], the row of dates'
/// choice (#1042), grouped as [lineupGroups] groups them among the event's
/// [occurrences]:
///
/// - With no view, as on an event with no row, every group.
/// - Under Every date, the event's own games, then those whose date the
///   event no longer lists, which no date's view holds, so none is hidden.
/// - Under one date, that date's games, then the event's own, which cover
///   every date (#517).
List<LineupGroup> lineupGroupsFor(
  GamesDateView? view,
  List<LineupGame> games,
  List<EventOccurrence> occurrences,
) {
  final groups = lineupGroups(games, occurrences);
  return switch (view) {
    null => groups,
    EveryDateView() => [
      for (final group in groups)
        if (group.kind != LineupGroupKind.date) group,
    ],
    OneDateView(:final occurrenceId) => [
      for (final group in groups)
        if (group.kind == LineupGroupKind.date &&
            group.date?.id == occurrenceId)
          group,
      for (final group in groups)
        if (group.kind == LineupGroupKind.everyDate) group,
    ],
  };
}

/// Whether the Lineup sub-tab heads each of [groups] with what it is for
/// (#519), in [view] (#1042). With no view: on an event of two or more
/// [occurrences], or where a game's date is no longer among them, which
/// would otherwise show as if it were the one date's. Under Every date only
/// where a game's date is no longer among them, so its games read apart
/// from the event's own; the view names the rest. Under one date never: its
/// games come first, and the event's own are marked instead
/// ([lineupMarksEveryDate]). Otherwise the lineup is one list.
bool lineupDrawsHeaders(
  List<LineupGroup> groups,
  List<EventOccurrence> occurrences, {
  GamesDateView? view,
}) {
  final gone = groups.any((group) => group.kind == LineupGroupKind.goneDate);
  return switch (view) {
    null => occurrences.length >= 2 || gone,
    EveryDateView() => gone,
    OneDateView() => false,
  };
}

/// Whether a row of the event's own game says on its status line that it is
/// for every date (#519), in [view] (#1042), where the lineup draws
/// [headers] or doesn't ([lineupDrawsHeaders]): under one date, where the
/// event's own games follow the date's with no heading; and with no view,
/// where nothing heads them. Under Every date the view says it already, and
/// under headings the "Every date" heading does.
bool lineupMarksEveryDate(GamesDateView? view, {required bool headers}) =>
    switch (view) {
      OneDateView() => true,
      EveryDateView() => false,
      null => !headers,
    };

/// What [lineupAddGate] decides for the screen.
enum LineupAddGate {
  /// No direct add is built.
  hidden,

  /// A direct add is offered.
  open,
}

/// Whether the viewer is offered adding a game straight to the lineup on
/// [state] (#519), where the event's rules for the games in question work out
/// to [mode].
///
/// [LineupAddGate.open] only when all of these hold: their actions hold
/// [EventAction.addToLineup]; the detail has a row for them on the roster (a
/// household owner or admin with none can't be recorded as the adder); the
/// event isn't local-only; it takes writes at all ([takesDateWrites]); and
/// [mode] is [GameAdditionMode.direct] or [GameAdditionMode.hostOnly], the
/// two the server accepts a direct add under. Otherwise
/// [LineupAddGate.hidden].
LineupAddGate lineupAddGate(
  EventDetailReady state, {
  required GameAdditionMode mode,
}) {
  final event = state.detail.snapshot.event;

  final allowed = switch (mode) {
    GameAdditionMode.direct || GameAdditionMode.hostOnly => true,
    GameAdditionMode.requiresVote ||
    GameAdditionMode.hostApproval ||
    GameAdditionMode.unknown => false,
  };

  return allowed &&
          state.actions.contains(EventAction.addToLineup) &&
          state.detail.attendance != null &&
          !event.isLocalOnly &&
          takesDateWrites(event)
      ? LineupAddGate.open
      : LineupAddGate.hidden;
}

/// What [lineupRemoveGate] decides for one game.
enum LineupRemoveGate {
  /// No remove is built.
  hidden,

  /// The lineup has started, so the game stays in it as the record of what
  /// was planned (#520). Shown with that reason, not hidden.
  started,

  /// Remove is offered.
  open,
}

/// Whether the viewer is offered taking [game] out of the lineup on [state],
/// as of [now] (#520).
///
/// [LineupRemoveGate.hidden] without [EventAction.removeFromLineup], or on a
/// local-only event. [LineupRemoveGate.started] when the server would refuse
/// the removal as the lineup having started: the event is cancelled, or was
/// before it was archived (the server reads its `cancelledAt`, and an archived
/// event arrives with that status, [wasCancelled]); for a
/// date's game, its date is no longer proposed or confirmed, or started
/// (`startDate <= now`); for the event's own game, the event has dates and
/// none is still to come, which is a proposed or confirmed date with no start
/// or one after [now]. An event with no dates hasn't started. A game whose
/// date the event doesn't list is [LineupRemoveGate.open], since the client
/// can't say, and the server answers. Otherwise [LineupRemoveGate.open].
LineupRemoveGate lineupRemoveGate(
  EventDetailReady state,
  LineupGame game, {
  required DateTime now,
}) {
  final event = state.detail.snapshot.event;
  final dates = state.detail.snapshot.occurrences;

  if (!state.actions.contains(EventAction.removeFromLineup) ||
      event.isLocalOnly) {
    return LineupRemoveGate.hidden;
  }

  if (wasCancelled(event)) return LineupRemoveGate.started;

  bool ahead(EventOccurrence date) =>
      switch (date.status) {
        OccurrenceStatus.proposed || OccurrenceStatus.confirmed => true,
        OccurrenceStatus.declined ||
        OccurrenceStatus.cancelled ||
        OccurrenceStatus.unknown => false,
      } &&
      (date.startDate == null || date.startDate!.isAfter(now));

  final started = switch (game.occurrenceId) {
    null => dates.isNotEmpty && !dates.any(ahead),
    final id => switch (dates.where((date) => date.id == id).firstOrNull) {
      null => false,
      final date => !ahead(date),
    },
  };

  return started ? LineupRemoveGate.started : LineupRemoveGate.open;
}

/// Whether the lineup [known] (null where it isn't read, [knownLineup]) holds
/// a game the pool row [offeredGameId] supplies, one a host could take out
/// (#520): its [lineupRemoveGate] isn't [LineupRemoveGate.started], as of
/// [now]. What a take-back's 409 names, for a game in the lineup, as the step
/// that frees it: a game whose lineup has started stays in it, which no host
/// can change.
bool lineupHoldsRemovable(
  EventDetailReady state,
  List<LineupGame>? known,
  String offeredGameId, {
  required DateTime now,
}) =>
    known?.any(
      (game) =>
          game.suppliedById == offeredGameId &&
          lineupRemoveGate(state, game, now: now) != LineupRemoveGate.started,
    ) ??
    false;
