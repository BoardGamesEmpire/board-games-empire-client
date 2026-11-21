/// The lineup on an event's Games tab (#519): its games grouped by the date
/// each is on.
library;

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

/// Whether the Lineup sub-tab heads each of [groups] with what it is for
/// (#519): on an event of two or more [occurrences], or where a game's date
/// is no longer among them, which would otherwise show as if it were the
/// one date's. Otherwise the lineup is one list, and the event's own games
/// are marked as covering every date instead.
bool lineupDrawsHeaders(
  List<LineupGroup> groups,
  List<EventOccurrence> occurrences,
) =>
    occurrences.length >= 2 ||
    groups.any((group) => group.kind == LineupGroupKind.goneDate);
