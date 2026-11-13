/// The games pool on an event's Games tab (#516): what its filter keeps,
/// whose games it holds, and whose a read of it names.
library;

import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the Games tab narrows the pool to: a search and the facets of the
/// shared filter sheet ([game], #851), and the people whose games it keeps
/// or, with [leaveOut], leaves out.
final class PoolFilter extends Equatable {
  const PoolFilter({
    this.game = const CollectionFilter(),
    this.attendeeIds = const {},
    this.leaveOut = false,
  });

  /// The search, and the facets the filter sheet and its chips set: content
  /// type, platform type, medium, publish year, players and play time, each
  /// of which can be flipped (#851). [filterPool] reads it as Collection's
  /// filter is read ([filterGames]).
  final CollectionFilter game;

  /// The roster rows chosen. Empty, the people don't narrow.
  final Set<String> attendeeIds;

  /// Whether the games of [attendeeIds] are the ones left out, rather than
  /// the ones kept. It narrows nothing while nobody is chosen.
  final bool leaveOut;

  /// Words to find in each game's title or subtitle, by
  /// [matchesSearchTerms], the rule Collection's search uses (#715): every
  /// term, ignoring case and the punctuation around each word. It is
  /// [game]'s own.
  String get query => game.query;

  /// Whether this leaves any game out that an empty filter would keep: a
  /// query with a term in it, a facet in use, or someone chosen.
  bool get narrows => game.narrows || attendeeIds.isNotEmpty;

  /// This filter with the person [id] let go. Letting the last go turns
  /// leave-out off, so a choice made later never starts out left out.
  PoolFilter withoutPerson(String id) {
    final ids = {...attendeeIds}..remove(id);
    return copyWith(attendeeIds: ids, leaveOut: ids.isNotEmpty && leaveOut);
  }

  /// This filter with the fields given changed. A [query] is set on [game],
  /// the one given or this filter's own.
  PoolFilter copyWith({
    String? query,
    CollectionFilter? game,
    Set<String>? attendeeIds,
    bool? leaveOut,
  }) {
    final next = game ?? this.game;
    return PoolFilter(
      game: query == null ? next : next.copyWith(query: query),
      attendeeIds: attendeeIds ?? this.attendeeIds,
      leaveOut: leaveOut ?? this.leaveOut,
    );
  }

  @override
  List<Object?> get props => [game, attendeeIds, leaveOut];
}

/// The games of [games] that [filter] keeps, in their order (#516).
///
/// A game is kept when [PoolFilter.game] keeps it, by [filterGames], the
/// rules Collection's filter applies (#715, #851): every term of the query
/// in its title or its subtitle, and each facet in use matched, or not
/// matched where it is flipped. A game the server sent with no content
/// type, platform type or medium is in no set, so a facet that names some
/// drops it, and flipped keeps it. A query with no terms, blank or
/// punctuation alone, keeps every game. Then, while someone is chosen, it is
/// kept when its attendee is one of them, or with [PoolFilter.leaveOut],
/// when it isn't. Each offered copy is a game of its own, so two people
/// bringing the same title are two, and leaving one of them out keeps the
/// other's.
List<OfferedGame> filterPool(List<OfferedGame> games, PoolFilter filter) {
  final people = filter.attendeeIds;
  return [
    for (final game in filterGames(games, filter.game, factsOf: _factsOf))
      if (people.isEmpty || people.contains(game.attendeeId) != filter.leaveOut)
        game,
  ];
}

/// What [filterGames] reads of an offered [game]: what the pool's row
/// carries of it and of the owner's copy (#851). The rows are flat, so
/// none is marked as an expansion without its base game, and the pool's
/// sheet doesn't offer that switch.
FilterableGame _factsOf(OfferedGame game) => (
  title: game.title,
  subtitle: game.subtitle,
  contentType: game.contentType,
  platformType: game.platformType,
  medium: game.medium,
  publishYear: game.publishYear,
  minPlayers: game.minPlayers,
  maxPlayers: game.maxPlayers,
  minPlayTime: game.minPlayTime,
  maxPlayTime: game.maxPlayTime,
);

/// The roster's names by row id, which name whoever offered a pool row, on
/// the row and wherever else the screen says whose games they are (#518):
/// empty where the roster is withheld or not read. A row with no name maps
/// to null, which each caller names as it says "someone".
Map<String, String?> poolNames(EventDetail detail) => {
  for (final row in detail.snapshot.attendees ?? const <EventAttendee>[])
    row.id: row.name,
};

/// The attendees whose games the pool holds: the cached roster's, or the
/// viewer's own where the roster is withheld, or none. The screen reads the
/// pool again when these change, and a read sends [poolReadIds].
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

/// The attendees a read of the pool names (#851): null, for every
/// attendee's games, where the roster is a non-empty list, and otherwise
/// [poolAttendeeIds], the viewer's own row or none.
///
/// The read serves the whole event's games in one go, and caps the ids it
/// takes at 100, so a read the roster allows names nobody. Where the roster
/// is withheld or not read, it narrows to the viewer's own games.
List<String>? poolReadIds(EventDetail detail) {
  final roster = detail.snapshot.attendees;
  if (roster != null && roster.isNotEmpty) return null;
  return poolAttendeeIds(detail);
}
