import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The home page's sections, in their fixed order (#613): upcoming events and
/// stats, side by side where the window has room, above the two shelves. A null
/// slot draws nothing and takes no gap, so each section ships on its own.
///
/// A [StatefulWidget] for one reason: moving between a [Row] and a [Column]
/// would otherwise remount the two paired sections, along with the blocs they
/// provide, each time the window crosses the breakpoint. Holding a [GlobalKey]
/// for each moves them instead, so they keep their state and focus.
class HomeSections extends StatefulWidget {
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
  State<HomeSections> createState() => _HomeSectionsState();
}

class _HomeSectionsState extends State<HomeSections> {
  final _upcomingEventsKey = GlobalKey(debugLabel: 'home_upcoming_events');
  final _statsKey = GlobalKey(debugLabel: 'home_stats');

  /// Whether the window is wide enough for the pair to sit side by side.
  ///
  /// Reads the window rather than a [LayoutBuilder], because the threshold is
  /// about the window (#613). A [LayoutBuilder] here sees the window less the
  /// page's padding, capped at the page's measure. Measured, that reaches 840
  /// only at a window of 888, so it would cross the breakpoint 48dp late, and
  /// lowering the measure below the breakpoint would stop it crossing at all.
  bool _isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >=
      BgeTokens.of(context).breakpointExpanded;

  @override
  Widget build(BuildContext context) {
    final upcomingEvents = _keyed(_upcomingEventsKey, widget.upcomingEvents);
    final stats = _keyed(_statsKey, widget.stats);

    final sections = <Widget>[
      if (upcomingEvents != null && stats != null && _isWide(context))
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: upcomingEvents),
            const BgeGap.lg(axis: Axis.horizontal),
            Expanded(child: stats),
          ],
        )
      else ...[
        ?upcomingEvents,
        ?stats,
      ],
      // Keyed so that a slot filling or emptying can't hand one shelf's state
      // to the other, which the same type in the next position would be given.
      ?_keyed(const ValueKey('home_newest_games'), widget.newestGames),
      ?_keyed(const ValueKey('home_something_to_play'), widget.somethingToPlay),
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
