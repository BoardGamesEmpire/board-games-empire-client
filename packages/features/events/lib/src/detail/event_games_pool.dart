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

  /// Matched against each game's title, trimmed, ignoring case.
  final String query;

  /// The roster rows chosen. Empty, the people don't narrow.
  final Set<String> attendeeIds;

  /// Whether the games of [attendeeIds] are the ones left out, rather than
  /// the ones kept. It narrows nothing while nobody is chosen.
  final bool leaveOut;

  /// Whether this leaves any game out that an empty filter would keep.
  bool get narrows => query.trim().isNotEmpty || attendeeIds.isNotEmpty;

  @override
  List<Object?> get props => [query, attendeeIds, leaveOut];
}

/// The games of [games] that [filter] keeps, in their order (#516).
///
/// A game is kept when its title holds the query and, while someone is
/// chosen, when its attendee is one of them, or with
/// [PoolFilter.leaveOut], when it isn't. Each offered copy is a game of its
/// own, so two people bringing the same title are two, and leaving one of
/// them out keeps the other's.
List<OfferedGame> filterPool(List<OfferedGame> games, PoolFilter filter) {
  final query = filter.query.trim().toLowerCase();
  final people = filter.attendeeIds;
  return [
    for (final game in games)
      if ((query.isEmpty || game.title.toLowerCase().contains(query)) &&
          (people.isEmpty ||
              people.contains(game.attendeeId) != filter.leaveOut))
        game,
  ];
}

/// The ids to read the pool for: the cached roster's, or the viewer's own
/// where the roster is withheld, or none.
///
/// A roster that is a non-empty list gives every row's id, in its order.
/// A roster that is null, or withheld (an empty list), gives the viewer's
/// own row alone, where they have one: their own games are theirs to see.
/// With neither there is nothing to read, and the tab says the games aren't
/// shown.
List<String> poolAttendeeIds(EventDetail detail) {
  final roster = detail.snapshot.attendees;
  if (roster != null && roster.isNotEmpty) {
    return [for (final row in roster) row.id];
  }
  final viewer = detail.attendance;
  return viewer == null ? const [] : [viewer.id];
}
