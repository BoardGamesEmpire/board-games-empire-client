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

/// The Games tab's sub-tabs (#945), in the order its second bar shows them.
/// Each one's `index` is its place in the sub-tabs' [TabController].
enum EventGamesSection {
  /// The games lined up for the event (#519).
  lineup,

  /// The nominations for the event's games.
  nominations,

  /// The games the people coming offer to bring.
  pool,
}

/// Where the event screen stands, as its location names it (#856): Details,
/// or one of the Games tab's sub-tabs. Each one's [name] is its value of the
/// location's `tab` parameter.
enum EventScreenTab {
  /// The Details tab, which a location with no `tab` names.
  details,

  /// The Games tab, on Lineup.
  lineup,

  /// The Games tab, on Nominations.
  nominations,

  /// The Games tab, on Pool.
  pool;

  /// Where the screen stands with its tab bar on [tab] and the Games tab's
  /// sub-tabs on [section]: Details whatever the sub-tabs stand on, and on
  /// Games the sub-tab.
  factory EventScreenTab.of(EventDetailTab tab, EventGamesSection section) =>
      switch (tab) {
        EventDetailTab.details => EventScreenTab.details,
        EventDetailTab.games => switch (section) {
          EventGamesSection.lineup => EventScreenTab.lineup,
          EventGamesSection.nominations => EventScreenTab.nominations,
          EventGamesSection.pool => EventScreenTab.pool,
        },
      };

  /// The tab the location's `tab` parameter, [value], names: none, `details`
  /// or a value that names no tab is Details, and `games` is the Games tab
  /// on its first sub-tab, Lineup. Case matters.
  static EventScreenTab parse(String? value) => switch (value) {
    'games' => lineup,
    final value? => values.asNameMap()[value] ?? details,
    null => details,
  };

  /// The location's `tab` parameter for this tab: none for Details, which a
  /// location names by leaving it out, and otherwise its [name].
  String? get query => this == details ? null : name;

  /// The screen's tab this names: Details, or Games for a sub-tab.
  EventDetailTab get tab => switch (this) {
    EventScreenTab.details => EventDetailTab.details,
    EventScreenTab.lineup ||
    EventScreenTab.nominations ||
    EventScreenTab.pool => EventDetailTab.games,
  };

  /// The Games tab's sub-tab this names, or null for Details.
  EventGamesSection? get section => switch (this) {
    EventScreenTab.details => null,
    EventScreenTab.lineup => EventGamesSection.lineup,
    EventScreenTab.nominations => EventGamesSection.nominations,
    EventScreenTab.pool => EventGamesSection.pool,
  };
}

/// How the event screen tells where the user's choice has settled it (#856):
/// [EventDetailScreen.onTabChanged], with the screen's context.
typedef EventTabChanged = void Function(
  BuildContext context,
  EventScreenTab tab,
);

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

/// The Games tab's sub-tab bar (#945): Lineup, then Nominations, then Pool,
/// under the screen's own bar.
///
/// Material's secondary [TabBar], not scrollable, so each sub-tab has the
/// tab role, says whether it is selected and where it stands, and takes a
/// third of the bar. Its labels scale down as the screen's own bar's do,
/// rather than being cut.
///
/// Choosing a sub-tab moves no focus: the Games tab swaps what is under the
/// bar and keeps the bar, so focus stays on the sub-tab pressed.
class EventGamesSectionBar extends StatelessWidget {
  const EventGamesSectionBar({required this.controller, super.key});

  /// Length 3: [EventGamesSection.lineup], [EventGamesSection.nominations],
  /// then [EventGamesSection.pool].
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return TabBar.secondary(
      controller: controller,
      tabs: [
        for (final section in EventGamesSection.values)
          Tab(
            key: EventDetailScreen.sectionTabKey(section),
            child: _TabLabel(switch (section) {
              EventGamesSection.lineup => l10n.eventsGamesSectionLineup,
              EventGamesSection.nominations =>
                l10n.eventsGamesSectionNominations,
              EventGamesSection.pool => l10n.eventsGamesSectionPool,
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
