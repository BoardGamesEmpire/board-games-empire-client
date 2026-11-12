/// The games pool on an event's Games tab (#516): what its filter keeps, and
/// whose games a read of it names.
library;

import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the Games tab narrows the pool to: a title search, and the people
/// whose games it keeps or, with [leaveOut], leaves out.
final class PoolFilter extends Equatable {
  const PoolFilter({
    this.query = '',
    this.attendeeIds = const {},
    this.leaveOut = false,
  });

  /// Words to find in each game's title, by [matchesSearchTerms], the rule
  /// Collection's search uses (#715): every term, ignoring case and the
  /// punctuation around each word.
  final String query;

  /// The roster rows chosen. Empty, the people don't narrow.
  final Set<String> attendeeIds;

  /// Whether the games of [attendeeIds] are the ones left out, rather than
  /// the ones kept. It narrows nothing while nobody is chosen.
  final bool leaveOut;

  /// Whether this leaves any game out that an empty filter would keep: a
  /// query with a term in it, or someone chosen.
  bool get narrows =>
      !matchesSearchTerms(query, const []) || attendeeIds.isNotEmpty;

  /// This filter with the person [id] let go. Letting the last go turns
  /// leave-out off, so a choice made later never starts out left out.
  PoolFilter withoutPerson(String id) {
    final ids = {...attendeeIds}..remove(id);
    return copyWith(attendeeIds: ids, leaveOut: ids.isNotEmpty && leaveOut);
  }

  /// This filter with the fields given changed.
  PoolFilter copyWith({
    String? query,
    Set<String>? attendeeIds,
    bool? leaveOut,
  }) => PoolFilter(
    query: query ?? this.query,
    attendeeIds: attendeeIds ?? this.attendeeIds,
    leaveOut: leaveOut ?? this.leaveOut,
  );

  @override
  List<Object?> get props => [query, attendeeIds, leaveOut];
}

/// The games of [games] that [filter] keeps, in their order (#516).
///
/// A game is kept when every term of the query is in its title
/// ([matchesSearchTerms], as Collection's search matches, #715) and, while
/// someone is chosen, when its attendee is one of them, or with
/// [PoolFilter.leaveOut], when it isn't. A query with no terms, blank or
/// punctuation alone, keeps every game. Each offered copy is a game of its
/// own, so two people bringing the same title are two, and leaving one of
/// them out keeps the other's.
List<OfferedGame> filterPool(List<OfferedGame> games, PoolFilter filter) {
  final people = filter.attendeeIds;
  return [
    for (final game in games)
      if (matchesSearchTerms(filter.query, [game.title]) &&
          (people.isEmpty ||
              people.contains(game.attendeeId) != filter.leaveOut))
        game,
  ];
}

/// The roster's names by row id, which name whoever offered a pool row, on
/// the row and wherever else the screen says whose games they are (#518):
/// empty where the roster is withheld or not read. A row with no name maps
/// to null, which each caller names as it says "someone".
Map<String, String?> poolNames(EventDetail detail) => {
  for (final row in detail.snapshot.attendees ?? const <EventAttendee>[])
    row.id: row.name,
};

/// The ids to read the pool for: the cached roster's, or the viewer's own
/// where the roster is withheld, or none.
///
/// A roster that is a non-empty list gives every row's id, in its order.
/// A roster that is null, or withheld (an empty list), gives the viewer's
/// own row alone, where they have one: their own games are theirs to see.
/// With neither there is nothing to read. The tab tells the two apart: a
/// withheld roster means the games aren't shown, and one not read (null)
/// waits for the event's read to bring it.
List<String> poolAttendeeIds(EventDetail detail) {
  final roster = detail.snapshot.attendees;
  if (roster != null && roster.isNotEmpty) {
    return [for (final row in roster) row.id];
  }
  final viewer = detail.attendance;
  return viewer == null ? const [] : [viewer.id];
}
