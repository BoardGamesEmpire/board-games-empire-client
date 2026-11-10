import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:flutter/material.dart';

/// The event screen's tabs (#516), in the order its bar shows them. Each
/// one's [index] is its place in the bar's [TabController].
enum EventDetailTab {
  /// The event itself: its header, its dates and who's coming.
  details,

  /// The games the people coming offer to bring.
  games,
}

/// The event screen's tab bar (#516): Details, then Games.
///
/// Material's [TabBar], not scrollable, so each tab has the tab role, says
/// whether it is selected and where it stands ("tab 1 of 2"), and takes half
/// the bar. A label too wide for its half at large text scales down to fit
/// rather than being cut, as the app's chip labels do: a tab is one line
/// tall and can't wrap.
///
/// Choosing a tab moves no focus: the screen swaps what is under the bar and
/// keeps the bar, so focus stays on the tab pressed.
class EventDetailTabBar extends StatelessWidget {
  const EventDetailTabBar({required this.controller, super.key});

  /// Length 2: [EventDetailTab.details], then [EventDetailTab.games].
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return TabBar(
      controller: controller,
      tabs: [
        for (final tab in EventDetailTab.values)
          Tab(
            key: EventDetailScreen.tabKey(tab),
            child: _TabLabel(switch (tab) {
              EventDetailTab.details => l10n.eventsDetailTabDetails,
              EventDetailTab.games => l10n.eventsDetailGames,
            }),
          ),
      ],
    );
  }
}

/// A tab's label, scaled down to fit its tab where it would otherwise be cut,
/// and at its own size everywhere else.
class _TabLabel extends StatelessWidget {
  const _TabLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(text));
}
