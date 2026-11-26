import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:models/domain.dart' show GameAdditionMode;
import 'package:ui/ui.dart' show focusIsFree;

/// The event screen's tabs (#516), in the order its bar shows them. Each
/// one's [index] is its place in the bar's [TabController].
enum EventDetailTab {
  /// The event itself: its header, its dates and who's coming.
  details,

  /// The games the people coming offer to bring.
  games,
}

/// The Games tab's sub-tabs (#945), in the order its second bar shows them.
/// The bar shows those [visibleSections] gives, in this order, so a
/// sub-tab's place in the sub-tabs' [TabController] is its place among
/// those.
enum EventGamesSection {
  /// The games lined up for the event (#519).
  lineup,

  /// The nominations for the event's games.
  nominations,

  /// The games the people coming offer to bring.
  pool,
}

/// The sub-tabs the Games tab's bar shows (#945) under [mode], the
/// game-addition mode of the view in use (`viewMode`, #519): all three, but
/// for Nominations under a host-only mode, where nothing can be nominated,
/// while no nomination is in the view ([nominationsInViewExist]). One made
/// before the mode turned host-only keeps it, so it stays reachable. An
/// unknown mode (null), as a date's is while its rules are still to come
/// from a read (#1063), follows the host-only rule.
List<EventGamesSection> visibleSections({
  required GameAdditionMode? mode,
  required bool nominationsInViewExist,
}) => [
  for (final section in EventGamesSection.values)
    if (section != EventGamesSection.nominations ||
        (mode != null && mode != GameAdditionMode.hostOnly) ||
        nominationsInViewExist)
      section,
];

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

/// How the event screen tells where the user's choice has settled it (#856,
/// #1042): [EventDetailScreen.onLocationChanged], with the screen's context,
/// the tab it stands on and the date beside it, as the location's `date`
/// parameter carries it, or null for none.
typedef EventLocationChanged = void Function(
  BuildContext context,
  EventScreenTab tab,
  String? date,
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
/// under the screen's own bar, each that [sections] holds ([visibleSections],
/// #519).
///
/// Material's secondary [TabBar], not scrollable, so each sub-tab has the
/// tab role, says whether it is selected and where it stands among those
/// shown, and takes an equal share of the bar. Its labels scale down as the
/// screen's own bar's do, rather than being cut.
///
/// Choosing a sub-tab moves no focus: the Games tab swaps what is under the
/// bar and keeps the bar, so focus stays on the sub-tab pressed.
///
/// As [sections] changes, focus on one of its sub-tabs stays on that
/// sub-tab where it is still shown, and goes to the one chosen where it has
/// gone: the bar's tabs are built by their place, so without this focus
/// would stay with the place, now another sub-tab's, or be lost with a
/// place that went. Focus in what a chosen sub-tab that has gone showed,
/// lost with it, goes to the one chosen in its place too. Once the frame
/// that changes them has ended, and only while focus is still where the
/// change left it: on the place it was in, or, for a control that went, on
/// nothing or the page.
class EventGamesSectionBar extends StatefulWidget {
  const EventGamesSectionBar({
    required this.sections,
    required this.controller,
    this.onTap,
    super.key,
  });

  /// The sub-tabs shown, in their order ([visibleSections]).
  final List<EventGamesSection> sections;

  /// As long as [sections], each tab at its place among them.
  final TabController controller;

  /// Called with the place of each sub-tab the user chooses, however it is
  /// pressed, the one already chosen included, which changes no index.
  final ValueChanged<int>? onTap;

  @override
  State<EventGamesSectionBar> createState() => _EventGamesSectionBarState();
}

class _EventGamesSectionBarState extends State<EventGamesSectionBar> {
  @override
  void didUpdateWidget(EventGamesSectionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (listEquals(oldWidget.sections, widget.sections)) return;
    final held = FocusManager.instance.primaryFocus;
    if (held == null || held is FocusScopeNode) return;
    // The sub-tab whose tab holds focus, if one does, else whether the
    // sub-tab chosen, and so what it showed, has gone.
    final onTab = [
      for (final section in oldWidget.sections)
        if (_tabFocus(section) == held) section,
    ].firstOrNull;
    final chosen = oldWidget.sections[oldWidget.controller.index];
    if (onTab == null && widget.sections.contains(chosen)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final focus = FocusManager.instance.primaryFocus;
      if (onTab == null) {
        // Only where the control went with what the sub-tab showed.
        if ((held.context?.mounted ?? false) ||
            !focusIsFree(context, untouched: held)) {
          return;
        }
      } else if (focus != null && focus != held) {
        // Moved meanwhile.
        return;
      }
      final target = onTab != null && widget.sections.contains(onTab)
          ? onTab
          : widget.sections[widget.controller.index];
      _tabFocus(target)?.requestFocus();
    });
  }

  /// The focus of [section]'s tab, where the bar shows it: its ink well's,
  /// the nearest focus above its label.
  // This leans on how Material's TabBar builds its tabs: one InkWell each,
  // with no key, so reused by place as the tabs change, each with a focus
  // node of its own, and the label we give inside it. Should a Flutter
  // upgrade change that, these tests in event_detail_tabs_test.dart fail
  // first: 'focus on Nominations as it leaves goes to Lineup, the sub-tab
  // chosen', 'focus on Pool stays on Pool as Nominations leaves and comes
  // back', 'focus in the Nominations list as it leaves goes to Lineup', and
  // 'focus elsewhere stays where it is as Nominations leaves'.
  FocusNode? _tabFocus(EventGamesSection section) {
    final key = EventDetailScreen.sectionTabKey(section);
    Element? tab;
    void visit(Element element) {
      if (tab != null) return;
      if (element.widget.key == key) {
        tab = element;
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    final found = tab;
    return found == null ? null : Focus.maybeOf(found, createDependency: false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return TabBar.secondary(
      controller: widget.controller,
      onTap: widget.onTap,
      tabs: [
        for (final section in widget.sections)
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
