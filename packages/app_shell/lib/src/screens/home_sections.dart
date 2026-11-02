import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The home page's sections, in their fixed order (#613): upcoming events,
/// stats, then the two shelves. One column at every width (#669): the events
/// row moves side to side, and beside stats it would show a card and a half. A
/// null slot draws nothing and takes no gap, so each section ships on its own.
///
/// Each slot is keyed, so that a slot filling or emptying can't hand its state
/// to the section after it, which the next position would otherwise give that
/// section's element. Events and stats come from different packages, and the
/// two shelves share a type, so without a key a section could take on its
/// neighbour's blocs, scroll offset and focus.
class HomeSections extends StatelessWidget {
  const HomeSections({
    this.upcomingEvents,
    this.stats,
    this.newestGames,
    this.somethingToPlay,
    super.key,
  });

  final Widget? upcomingEvents;
  final Widget? stats;
  final Widget? newestGames;
  final Widget? somethingToPlay;

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      ?_keyed(const ValueKey('home_upcoming_events'), upcomingEvents),
      ?_keyed(const ValueKey('home_stats'), stats),
      ?_keyed(const ValueKey('home_newest_games'), newestGames),
      ?_keyed(const ValueKey('home_something_to_play'), somethingToPlay),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, section) in sections.indexed) ...[
          if (index > 0) const BgeGap.xl(),
          section,
        ],
      ],
    );
  }

  static Widget? _keyed(Key key, Widget? section) =>
      section == null ? null : KeyedSubtree(key: key, child: section);
}
