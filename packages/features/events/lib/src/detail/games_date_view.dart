/// Which of an event's dates the Games tab shows (#1042): every date, or one,
/// chosen from the row of dates above its sub-tabs and kept in the screen's
/// location as its `date` parameter; where the row shows, which view it opens
/// on, and the game-addition mode each view is under (#519).
///
/// Nothing here reads the network or a bloc. The Games tab's controller holds
/// the view and asks these what it means.
library;

import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:models/domain.dart';

/// What the Games tab shows of an event's dates (#1042), on an event with a
/// row of them ([showsDateRow]).
sealed class GamesDateView extends Equatable {
  const GamesDateView();

  /// What the screen's location names this view by, as its `date`
  /// parameter: `all`, or the date's id.
  String get query;
}

/// Every date, first in the row (#1042): the event's own lineup games and
/// whole-event nominations, under the event's rules.
final class EveryDateView extends GamesDateView {
  const EveryDateView();

  /// The location's `date` for Every date.
  static const allQuery = 'all';

  @override
  String get query => allQuery;

  @override
  List<Object?> get props => const [];
}

/// One of the event's dates, by its id (#1042): that date's lineup games and
/// nominations, then the event's own, under that date's rules.
final class OneDateView extends GamesDateView {
  const OneDateView(this.occurrenceId);

  /// The date's id.
  final String occurrenceId;

  @override
  String get query => occurrenceId;

  @override
  List<Object?> get props => [occurrenceId];
}

/// Whether the Games tab has a row of dates (#1042): on an event with two
/// dates or more. An event with one, or none, has a single view.
bool showsDateRow(EventSnapshot s) => s.occurrences.length >= 2;

/// The view the Games tab opens on where the location names none it can
/// show (#1042): the next date still to come, of [nominatableDates] as of
/// [now], by when it starts, not by its place in the row, since a date
/// added later can start sooner. A date still to be set comes after those
/// with a start, and dates that tie keep the row's order. Once none is
/// still to come, Every date.
GamesDateView defaultDateView(EventDetail d, {required DateTime now}) {
  EventOccurrence? next;
  for (final date in nominatableDates(d, now: now)) {
    final start = date.startDate;
    if (start == null) {
      next ??= date;
      continue;
    }
    final soonest = next?.startDate;
    if (soonest == null || start.isBefore(soonest)) next = date;
  }
  return next == null ? const EveryDateView() : OneDateView(next.id);
}

/// The view the location's `date`, [query], opens on [d] (#1042): none
/// where it has no row ([showsDateRow]); Every date for `all`; the date it
/// names, where that is one of the event's, passed or not; and otherwise,
/// none named, an empty one, or one naming no date of the event, as a date
/// since removed, the default ([defaultDateView]).
GamesDateView? dateViewOf(
  String? query,
  EventDetail d, {
  required DateTime now,
}) {
  if (!showsDateRow(d.snapshot)) return null;
  if (query == EveryDateView.allQuery) return const EveryDateView();
  for (final date in d.snapshot.occurrences) {
    if (date.id == query) return OneDateView(date.id);
  }
  return defaultDateView(d, now: now);
}

/// The game-addition mode of [occurrenceId]'s date on [d] (#519), or of the
/// whole event where it is null: the event's own for the whole event, and
/// for a date, its effective mode (`gamePolicyFor`), its own override where
/// it sets one, else the event's.
///
/// Null, unknown, for a date whose policy is unread while a detail read
/// runs, or while a read has carried the dates' policies and they are on
/// their way to the cache (`occurrencePoliciesArriving`) (#1063): until they
/// land, the event's mode may not be the date's, and nothing that depends on
/// the mode is built. No read running, one that failed, or one that carried
/// no policies, as for a viewer refused them, leaves the event's mode, so
/// nothing waits for policies that aren't coming; the server enforces the
/// date's own. So does a read running after one that carried none
/// (`occurrencePoliciesWithheld`): it won't bring them either. And so does
/// a read running after one that failed (`refreshFailed`, which holds until
/// a read succeeds), and the policies that retry carried on their way to the
/// cache (`occurrencePoliciesArrivingAfterFailure`): the controls the
/// failure left stay through the retry rather than going and coming back.
/// A press held meanwhile still waits for the policies (`readEnded`).
GameAdditionMode? scopeMode(EventDetailReady d, String? occurrenceId) {
  final snapshot = d.detail.snapshot;
  final coming =
      d.occurrencePoliciesArriving &&
          !d.occurrencePoliciesArrivingAfterFailure ||
      d.reading && !d.occurrencePoliciesWithheld && !d.refreshFailed;
  if (occurrenceId != null && coming && snapshot.occurrencePolicies == null) {
    return null;
  }
  return snapshot.gamePolicyFor(occurrenceId).gameAdditionMode;
}

/// The game-addition mode of [view] on [d] (#519, [scopeMode]): a date's in
/// that date's view, unknown (null) while its policy is unread and a read
/// runs or it is on its way to the cache (#1063), and the event's
/// under Every date or where there is no row (null).
GameAdditionMode? viewMode(EventDetailReady d, GamesDateView? view) =>
    scopeMode(d, switch (view) {
      OneDateView(:final occurrenceId) => occurrenceId,
      EveryDateView() || null => null,
    });
