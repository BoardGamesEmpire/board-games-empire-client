import 'dart:async';

import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_lineup_bloc.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_lineup.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:events/src/widgets/event_game_quick_look.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart'
    show CollectionFilter, EventNomination, EventOccurrence, LineupGame;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the Games tab keeps across the screen's rebuilds (#516): its sub-tabs'
/// controller (#945), its filter, whether it has been shown, the ids the pool
/// was last asked with, how the pool's last read ended and how the nominations'
/// (#517) and the lineup's (#519) did, the nominations' own filter and order
/// (#517), the focus nodes a control that leaves hands focus on to, and what
/// the tab's quick looks reach the screen by (#957).
///
/// It notifies its listeners when the chosen sub-tab changes, once for each
/// change and as the change starts, and when the sub-tabs' controller is
/// replaced, so the screen's page, which listens to it, builds on the new one.
///
/// One per screen, held by [EventGamesTabScope] above the detail's builder,
/// beside the tab controller, so no read, write, clock tick or switch to the
/// Details tab under it forgets either filter, and the screen reads the pool,
/// the nominations and the lineup after a detail read only once the tab has
/// been shown.
class EventGamesTabController extends ChangeNotifier {
  PoolFilter _filter = const PoolFilter();
  NominationFilter _nominationFilter = const NominationFilter();
  NominationSort _nominationSort = NominationSort.newest;
  int _searchEpoch = 0;
  bool _shown = false;
  bool _disposed = false;
  EventGamesLoad? _settled;
  EventNominationsLoad? _nominationsSettled;
  EventLineupLoad? _lineupSettled;

  late TabController _sections;

  /// The screen's clock, which a quick look reads as the tab does (#957).
  DateTime Function() get clock => _clock;
  DateTime Function() _clock = DateTime.now;

  /// Tells its listeners each time the screen's clock passes one of the
  /// page's time boundaries (#957): the event's start or end, a proposed
  /// date passing, a nomination's deadline passing. The page builds itself
  /// again then; a quick look, on the root navigator outside the page,
  /// listens here, so it moves on at the same instants by the same clock
  /// ([clock]) rather than a timer of its own that could disagree.
  Listenable get clockTicks => _clockTicks;
  final _ClockTicks _clockTicks = _ClockTicks();

  /// Tells [clockTicks]' listeners the screen's clock passed a boundary.
  /// For the page's clock to call.
  void clockTicked() => _clockTicks.tick();

  /// Opens a game's page from a quick look's View game (#957):
  /// [EventDetailScreen.onOpenGame]. Null offers no View game.
  OpenEventGame? get openGame => _openGame;
  OpenEventGame? _openGame;

  /// Takes the screen's [clock] and its way to a game's page, [openGame],
  /// as the scope is built with them. For the scope only.
  void useScreen({
    required DateTime Function() clock,
    required OpenEventGame? openGame,
  }) {
    _clock = clock;
    _openGame = openGame;
  }

  /// The Games tab's sub-tabs' controller (#945), one tab for each
  /// [EventGamesSection]. [EventGamesTabScope] makes it before the first
  /// build and replaces it when the motion duration changes, so read it from
  /// here each build rather than keeping it.
  TabController get sections => _sections;

  /// The sub-tab chosen.
  EventGamesSection get section => EventGamesSection.values[sections.index];

  /// Starts the controller's life with [sections]. For the scope only.
  // A setter would pair with the `sections` getter and read as anyone's to
  // set; the scope's verbs, attach and replace, say which one tells the
  // listeners.
  // ignore: use_setters_to_change_properties
  void attachSections(TabController sections) => _sections = sections;

  /// Moves to [sections], which takes the place of the old controller at the
  /// same index, and tells the listeners once so the page builds on it. For
  /// the scope only.
  void replaceSections(TabController sections) {
    _sections = sections;
    notifyListeners();
  }

  /// Tells the listeners the chosen sub-tab changed. For the scope only,
  /// which calls it once for each change, as the change starts, the way the
  /// screen's own tab bar tells the page: the page swaps the list under the
  /// bar at once, not once the indicator has settled.
  void sectionChanged() => notifyListeners();

  /// What the tab narrows the pool to.
  PoolFilter get filter => _filter;

  /// What the Nominations section narrows the nominations to (#517).
  NominationFilter get nominationFilter => _nominationFilter;

  /// How the Nominations section orders the nominations it shows (#517).
  NominationSort get nominationSort => _nominationSort;

  /// Narrows the nominations to [filter], as each change in the Filters
  /// pop-up or a chip's removal makes it.
  void setNominationFilter(NominationFilter filter) {
    if (filter == _nominationFilter) return;
    _nominationFilter = filter;
    notifyListeners();
  }

  /// Orders the nominations by [sort].
  void setNominationSort(NominationSort sort) {
    if (sort == _nominationSort) return;
    _nominationSort = sort;
    notifyListeners();
  }

  /// The nominations' Filters button's focus: where Clear filters and the
  /// last chip's removal hand focus, and where it comes back once the
  /// Filters pop-up closes.
  final FocusNode nominationsFiltersFocus = FocusNode(
    debugLabel: 'Nominations filters',
  );

  /// The nominations' Sort button's focus, which its menu hands back as it
  /// closes.
  final FocusNode nominationsSortFocus = FocusNode(
    debugLabel: 'Nominations sort',
  );

  /// Clear filters' focus, in the state that says no nomination matches.
  final FocusNode nominationsClearFiltersFocus = FocusNode(
    debugLabel: 'Clear nominations filters',
  );

  /// Each nomination row, by the nomination's id.
  final Map<String, FocusNode> _nominationAreas = {};

  /// The node that holds nomination [id]'s row, made as it is first built
  /// and let go once the nomination is no longer held.
  FocusNode nominationArea(String id) => _nominationAreas.putIfAbsent(
    id,
    () => FocusNode(
      debugLabel: 'Nomination $id',
      canRequestFocus: false,
      skipTraversal: true,
    ),
  );

  /// Stops narrowing the nominations, from Clear filters, which leaves with
  /// the state it sits in, and hands focus to Filters once the frame that
  /// builds it has ended, if focus is free then ([focusIsFree], from
  /// [context], with Clear filters counting as free if it held focus at the
  /// press). The press arms it however it came. The order stays as chosen.
  void clearNominationFilters(BuildContext context) {
    final held = nominationsClearFiltersFocus.hasFocus
        ? nominationsClearFiltersFocus
        : null;
    setNominationFilter(const NominationFilter());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted || !focusIsFree(context, untouched: held)) return;
      if (nominationsFiltersFocus.context?.mounted ?? false) {
        nominationsFiltersFocus.requestFocus();
      }
    });
  }

  /// Moves on when the filter is cleared from outside the search field, so
  /// the field is built anew, empty. Never as the user types.
  int get searchEpoch => _searchEpoch;

  /// Whether the Games tab has shown on a ready detail at least once.
  bool get shown => _shown;

  /// Remembers that the Games tab has shown on a ready detail.
  void markShown() => _shown = true;

  /// The roster's ids ([poolAttendeeIds]) the pool was last asked to be read
  /// with, by the screen or by Try again, and whether that read was the
  /// whole event's ([poolReadIds] null, #851); or null before it has been
  /// asked, and again once the detail shows nobody to read it for. Each sets
  /// it as it asks. The viewer's id alone is read for either way, so the
  /// ids without the scope can't tell a roster of the viewer from one
  /// withheld.
  ({List<String> ids, bool wholeEvent})? requested;

  /// Holds Offer games, whose own node its held button keeps.
  final FocusNode offerArea = FocusNode(
    debugLabel: 'Offer games',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The People button's focus.
  final FocusNode peopleFocus = FocusNode(debugLabel: 'People');

  /// Holds the search field, whose own node the field keeps.
  final FocusNode searchArea = FocusNode(
    debugLabel: 'Search the games',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Each pool row, by the offered game's id.
  final Map<String, FocusNode> _poolRowAreas = {};

  /// The games whose Take back was pressed, and whose row leaving hands
  /// focus on.
  final Set<String> _armed = {};

  /// The node that holds offered game [id]'s whole row (#946), so a row that
  /// leaves can say it held focus, and the row after or before it can be
  /// handed it ([poolChanged]). Made as it is first built and let go once
  /// the game leaves the pool.
  FocusNode poolRowArea(String id) => _poolRowAreas.putIfAbsent(
    id,
    () => FocusNode(
      debugLabel: 'Pool row $id',
      canRequestFocus: false,
      skipTraversal: true,
    ),
  );

  /// Arms the hand-off from game [id]'s Take back: its own press, however
  /// it came (a key, a pointer or a screen reader's activation).
  void armTakeBack(String id) => _armed.add(id);

  /// Disarms it, for a take-back that sent nothing or left its row.
  void disarmTakeBack(String id) => _armed.remove(id);

  /// Each row's head, the button that opens its quick look (#957), by the
  /// entry it shows.
  final Map<EventGameEntry, FocusNode> _rowHeads = {};

  /// The focus of [entry]'s row head (#957), made as it is first built and
  /// let go once the entry leaves its list, as [poolRowArea]'s are.
  FocusNode rowHeadFocus(EventGameEntry entry) => _rowHeads.putIfAbsent(
    entry,
    () => FocusNode(debugLabel: 'Row head $entry'),
  );

  /// How many quick looks opened from the tab are open (#957).
  int _quickLooks = 0;

  /// Where each entry that left its list while a quick look was open left
  /// from (#957): the entries of the rows that stayed, the one in its place
  /// first, on to the last, then back from the one before it.
  final Map<EventGameEntry, List<EventGameEntry>> _leftFrom = {};

  /// Notes a quick look opening over the tab (#957), until [quickLookClosed].
  /// While one is open, neither list hands focus on as its rows leave: the
  /// quick look holds the focus, and a hand-off would take it from under
  /// the quick look's barrier. Each row that leaves notes where it left
  /// from instead, for [focusAfterQuickLook].
  void quickLookOpened() => _quickLooks++;

  /// Notes a quick look closing (#957).
  void quickLookClosed() => _quickLooks--;

  /// The pool's and the nominations' last outcomes to land while a quick
  /// look was open (#957), which it said.
  EventGamesOutcome? _poolSaid;
  EventNominationsOutcome? _nominationsSaid;

  /// Notes the pool's outcome going from [previous] to [outcome], as the
  /// pool emits it: one that lands while a quick look is open is said there.
  /// For the scope only.
  void poolOutcomeLanded(
    EventGamesOutcome? previous,
    EventGamesOutcome? outcome,
  ) {
    if (_quickLooks > 0 && outcome != null && !identical(outcome, previous)) {
      _poolSaid = outcome;
    }
  }

  /// Notes the nominations' outcome going from [previous] to [outcome], as
  /// [poolOutcomeLanded] does the pool's. For the scope only.
  void nominationsOutcomeLanded(
    EventNominationsOutcome? previous,
    EventNominationsOutcome? outcome,
  ) {
    if (_quickLooks > 0 && outcome != null && !identical(outcome, previous)) {
      _nominationsSaid = outcome;
    }
  }

  /// Whether [outcome], the pool's or the nominations', landed while a
  /// quick look was open, which said it (#957). The footer's banner of it
  /// is no live region, then or after: the pop-up's barrier hides the
  /// footer from a screen reader, and a live region that comes back into
  /// the tree as the barrier lifts is read out again.
  bool saidInQuickLook(Object outcome) =>
      identical(outcome, _poolSaid) || identical(outcome, _nominationsSaid);

  /// Hands focus on as the quick look of [entry] closes (#957), from
  /// [context], the scope's ([EventGamesTabScope.contextOf]), which outlives
  /// the row the quick look was opened from. To [entry]'s row head where its
  /// row is built. Where the row left while the quick look was open, to the
  /// head of the row now in its place, else of the nearest one before it,
  /// as [poolChanged], [nominationsChanged] and [lineupChanged] noted; else
  /// to the sub-tab's first header control: Filters for a nomination; for an
  /// offered copy, Offer games where it is built and enabled, else the
  /// search field. The lineup has none, so for a lineup game focus stays on
  /// the page (#519).
  ///
  /// Once the frame that closes it has ended, as the lists' own hand-offs
  /// are, and only while focus is free then ([focusIsFree]): on nothing, on
  /// the page, or where the close handed it back. The head took focus as it
  /// opened the quick look, however it was pressed, so while it is built
  /// the close hands focus back to it. Where it isn't, focus waits on the
  /// page meanwhile, not on an older control the page's focus history still
  /// holds, such as the search field, whose keyboard would open. Nothing
  /// while another page covers the tab's, as one View game opened does: that
  /// page has the focus.
  void focusAfterQuickLook(BuildContext context, EventGameEntry entry) {
    final order = _leftFrom.remove(entry) ?? const <EventGameEntry>[];
    if (_quickLooks == 0) _leftFrom.clear();
    if (!context.mounted || !(ModalRoute.isCurrentOf(context) ?? true)) return;
    final own = _rowHeads[entry];
    final back = own != null && _built(own) ? own : null;
    if (back == null) {
      FocusScope.of(context, createDependency: false).requestScopeFocus();
    }
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!context.mounted || !focusIsFree(context, untouched: back)) return;
        for (final each in [entry, ...order]) {
          final head = _rowHeads[each];
          if (head != null && _built(head)) {
            head.requestFocus();
            return;
          }
        }
        // As a list's own hand-off with no row left has it.
        switch (entry) {
          case OfferedCopyEntry():
            _focusPoolHeader();
          case NominationEntry():
            _focusNominationsHeader();
          case LineupEntry():
            _focusLineupHeader();
        }
      })
      // A post-frame callback asks for no frame of its own.
      ..ensureVisualUpdate();
  }

  /// Whether [node]'s control is built.
  static bool _built(FocusNode node) => node.context?.mounted ?? false;

  /// [rows] in the order a hand-off from the place [at] among them tries
  /// them: the one there first, on to the last, then back from the one
  /// before it.
  static List<T> _handOffOrder<T>(List<T> rows, int at) => [
    ...rows.skip(at),
    ...rows.take(at).toList().reversed,
  ];

  /// The controls of the row [area] holds: the outermost nodes inside it
  /// that keyboard navigation stops at, or would once enabled, in the order
  /// of its widgets, as `BgeFocusHandoff` reads an item's. One disabled for
  /// now keeps its place, as the choices a vote didn't send are while it is
  /// out, so a choice's place is the same in every row. None while the row
  /// isn't built.
  static List<FocusNode> _controlsOf(FocusNode? area) {
    final context = area?.context;
    if (area == null || context == null || !context.mounted) return const [];
    final byElement = <BuildContext, FocusNode>{
      for (final node in area.descendants)
        if (!node.skipTraversal) ?node.context: node,
    };
    final controls = <FocusNode>[];
    void visit(Element element) {
      final node = byElement[element];
      if (node != null) {
        controls.add(node);
      } else {
        element.visitChildren(visit);
      }
    }

    (context as Element).visitChildren(visit);
    return controls;
  }

  /// Where among the controls of the row [area] holds the primary focus is,
  /// as an index: 0, its head, where it is on none of them.
  static int _placeOfFocus(FocusNode area) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return 0;
    final index = _controlsOf(area).indexWhere(
      (control) => control == focus || focus.ancestors.contains(control),
    );
    return index < 0 ? 0 : index;
  }

  /// The control a row that left hands focus to, among [controls], the
  /// next row's, else the one before's (#946): the one at [place], where
  /// focus was among the controls of the row that left, so a head hands it
  /// to a head and a vote's choice to the same choice; else, where the row
  /// has none there that can take focus, its first that can, its head.
  /// Where [place] is null, the row's write ended with focus outside it, as
  /// a screen reader's activation leaves it: the first of its controls past
  /// its [head] that can take focus, its main action, else its head. Null
  /// where none can.
  static FocusNode? _inPlace(
    List<FocusNode> controls,
    int? place,
    FocusNode? head,
  ) {
    final open = controls.where((node) => node.canRequestFocus);
    if (place == null) {
      return open.where((node) => node != head).firstOrNull ?? open.firstOrNull;
    }
    final there = place < controls.length ? controls[place] : null;
    return there != null && there.canRequestFocus ? there : open.firstOrNull;
  }

  /// Lets go the row heads of the entries [left] says have left their list,
  /// and answers their nodes, to dispose of once their rows have gone.
  List<FocusNode> _releaseHeads(bool Function(EventGameEntry entry) left) => [
    for (final entry in [..._rowHeads.keys])
      if (left(entry)) _rowHeads.remove(entry)!,
  ];

  void setQuery(String query) => _set(_filter.copyWith(query: query));

  /// Narrows the pool by [filter]'s facets, as each change in the filter
  /// sheet or a chip's removal makes them (#851). The query stays as the
  /// search field set it: [filter]'s own, the one the sheet or the chip was
  /// given, is ignored.
  ///
  /// Once the controller is disposed, as it is with the screen, it does
  /// nothing: the sheet commits a range field's bounds after it has closed,
  /// which can be after the screen has gone (`showGameFilterSheet`).
  void setGameFilter(CollectionFilter filter) {
    if (_disposed) return;
    _set(_filter.copyWith(game: filter.copyWith(query: _filter.query)));
  }

  /// The pool's Filters button's focus (#851): where the last chip's
  /// removal hands focus, and where it comes back once the filter sheet
  /// closes.
  final FocusNode filtersFocus = FocusNode(debugLabel: 'Games filters');

  /// Chooses the person [id], or with [chosen] false, lets them go
  /// ([PoolFilter.withoutPerson]).
  void choose(String id, {required bool chosen}) => _set(
    chosen
        ? _filter.copyWith(attendeeIds: {..._filter.attendeeIds, id})
        : _filter.withoutPerson(id),
  );

  /// Leaves the people chosen out, or keeps only them.
  void setLeaveOut({required bool leaveOut}) => _set(
    _filter.copyWith(leaveOut: _filter.attendeeIds.isNotEmpty && leaveOut),
  );

  /// Whether the people chosen are "Not mine": the viewer, [viewerId], left
  /// out alone.
  bool isNotMine(String viewerId) =>
      _filter.leaveOut &&
      _filter.attendeeIds.length == 1 &&
      _filter.attendeeIds.contains(viewerId);

  /// Turns "Not mine" on, in place of whoever is chosen, or off, choosing
  /// nobody.
  void setNotMine(String viewerId, {required bool on}) => _set(
    _filter.copyWith(attendeeIds: on ? {viewerId} : const {}, leaveOut: on),
  );

  /// Clear filters' focus, in the state that says no game matches.
  final FocusNode clearFiltersFocus = FocusNode(debugLabel: 'Clear filters');

  /// Clears the search, the filter sheet's facets (#851) and the people, from
  /// Clear filters, which leaves with the state it sits in: the search field
  /// is emptied, and focus handed to People once the frame that builds it
  /// has ended, if focus is free then ([focusIsFree], from [context], with
  /// Clear filters counting as free if it held focus at the press). The
  /// press arms it however it came. Never to the search field: focus put on
  /// a text field opens the on-screen keyboard, over the games the user
  /// asked to see.
  void clearFilters(BuildContext context) {
    final held = clearFiltersFocus.hasFocus ? clearFiltersFocus : null;
    _searchEpoch++;
    _filter = const PoolFilter();
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted || !focusIsFree(context, untouched: held)) return;
      peopleFocus.requestFocus();
    });
  }

  /// Puts focus in the search field, where it is built.
  void focusSearch() =>
      searchArea.traversalDescendants.firstOrNull?.requestFocus();

  void _set(PoolFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    notifyListeners();
  }

  /// Notes how the pool's last read ended, from [state] as the pool emits
  /// it, whichever tab is showing then: what [drawnLoad] draws while the
  /// next read is out. A state with a read out, or none made, changes
  /// nothing.
  void poolEmitted(EventGamesState state) {
    switch (state.load) {
      case EventGamesLoad.idle || EventGamesLoad.loading:
        break;
      case final settled:
        _settled = settled;
    }
  }

  /// The load the tab draws [state] as: its own, or while a read is out, the
  /// last one a read ended with ([poolEmitted]), so a read again neither
  /// flashes a spinner over an answer nor announces it. Before any read has
  /// ended it is idle. It changes nothing, so a build may ask any number of
  /// times.
  EventGamesLoad drawnLoad(EventGamesState state) => switch (state.load) {
    EventGamesLoad.idle ||
    EventGamesLoad.loading => _settled ?? EventGamesLoad.idle,
    final settled => settled,
  };

  /// Whether the pool's [state] says what the viewer offers (#517): it holds
  /// games read before, or a read of it has answered, as [drawnLoad] draws
  /// it. Before a read has answered, an empty pool says nothing of what they
  /// offer; while one is out, the last to end stands. Read by the
  /// nominations' vote, on its rows and in a quick look (#957).
  bool isPoolRead(EventGamesState state) =>
      state.games.isNotEmpty || drawnLoad(state) == EventGamesLoad.loaded;

  /// Notes how the nominations' last read ended (#517), from [state] as the
  /// nominations' bloc emits it, whichever tab is showing then: what
  /// [drawnNominationsLoad] draws while the next read is out. A state with a
  /// read out, or none made, changes nothing.
  void nominationsEmitted(EventNominationsState state) {
    switch (state.load) {
      case EventNominationsLoad.idle || EventNominationsLoad.loading:
        break;
      case final settled:
        _nominationsSettled = settled;
    }
  }

  /// The load the Nominations section draws [state] as (#517): its own, or
  /// while a read is out, the last one a read ended with
  /// ([nominationsEmitted]), as [drawnLoad] is the pool's. So a read again
  /// neither flashes a spinner over "nothing nominated" nor takes a failure's
  /// Try again away while it runs. Before any read has ended it is idle. It
  /// changes nothing, so a build may ask any number of times.
  EventNominationsLoad drawnNominationsLoad(EventNominationsState state) =>
      switch (state.load) {
        EventNominationsLoad.idle || EventNominationsLoad.loading =>
          _nominationsSettled ?? EventNominationsLoad.idle,
        final settled => settled,
      };

  /// Notes how the lineup's last read ended (#519), from [state] as the
  /// lineup's bloc emits it, whichever tab is showing then: what
  /// [drawnLineupLoad] draws while the next read is out. A state with a read
  /// out, or none made, changes nothing.
  void lineupEmitted(EventLineupState state) {
    switch (state.load) {
      case EventLineupLoad.idle || EventLineupLoad.loading:
        break;
      case final settled:
        _lineupSettled = settled;
    }
  }

  /// The load the Lineup sub-tab draws [state] as (#519): its own, or while
  /// a read is out, the last one a read ended with ([lineupEmitted]), as
  /// [drawnNominationsLoad] is the nominations'. So a read again neither
  /// flashes a spinner over "nothing in the lineup" nor takes a failure's
  /// Try again away while it runs. Before any read has ended it is idle. It
  /// changes nothing, so a build may ask any number of times.
  EventLineupLoad drawnLineupLoad(EventLineupState state) =>
      switch (state.load) {
        EventLineupLoad.idle ||
        EventLineupLoad.loading => _lineupSettled ?? EventLineupLoad.idle,
        final settled => settled,
      };

  /// Each lineup row, by the lineup game's id (#519).
  final Map<String, FocusNode> _lineupAreas = {};

  /// The node that holds lineup game [id]'s row (#519), so a row that
  /// leaves can say it held focus ([lineupChanged]). Made as it is first
  /// built and let go once the game leaves the lineup.
  FocusNode lineupArea(String id) => _lineupAreas.putIfAbsent(
    id,
    () => FocusNode(
      debugLabel: 'Lineup row $id',
      canRequestFocus: false,
      skipTraversal: true,
    ),
  );

  /// Answers the lineup going from [previous] to [current], as the bloc
  /// emits it and before the frame that builds it (#519), from [context],
  /// the scope's, with [dates] the event's dates, which order its rows
  /// ([lineupGroups]).
  ///
  /// A row that leaves while focus is in it hands focus on once that frame
  /// has ended, as a nominations row does ([nominationsChanged]): to the
  /// next row shown, else the one before it, its head from its head. A row
  /// leaves only by a read, as nothing on it can be changed here. Where no
  /// row is left, focus stays on the page: the lineup has no header control
  /// to take it. Only while the Lineup sub-tab is chosen (#945), and not
  /// while a quick look is open (#957), where each row that leaves notes
  /// where it left from instead ([focusAfterQuickLook]).
  void lineupChanged(
    BuildContext context,
    EventLineupState previous,
    EventLineupState current, {
    required List<EventOccurrence> dates,
  }) {
    if (identical(previous.games, current.games)) return;
    List<String> shown(List<LineupGame> games) => [
      for (final group in lineupGroups(games, dates))
        for (final game in group.games) game.id,
    ];
    _rowsLeft(
      context,
      shownBefore: shown(previous.games),
      shownAfter: shown(current.games),
      kept: {for (final game in current.games) game.id},
      areas: _lineupAreas,
      entryOf: LineupEntry.new,
      list: EventGamesSection.lineup,
      // No write on the lineup can take its row away.
      handsOn: (_) => false,
      fallback: _focusLineupHeader,
    );
  }

  /// Answers the pool going from [previous] to [current], as the bloc
  /// emits it and before the frame that builds it: a pool row's hand-off
  /// (see "A pool row's hand-off" on [EventGamesTabScope]), from [context],
  /// the scope's. Only while the Pool sub-tab is chosen (#945): on
  /// Nominations the pool's rows aren't built, so the change disarms what it
  /// ends and hands nothing on. Nor while a quick look is open (#957), where
  /// each row that leaves notes where it left from instead
  /// ([focusAfterQuickLook]).
  void poolChanged(
    BuildContext context,
    EventGamesState previous,
    EventGamesState current,
  ) {
    // The take-back that ended here, if one did. A done one takes its row
    // away in this same change; any other end leaves the row. Either way
    // its arm is spent once this change is answered, so a later read that
    // takes the row away hands nothing on.
    final ended = current.takingBack == null ? previous.takingBack : null;
    if (identical(previous.games, current.games)) {
      if (ended != null) _armed.remove(ended);
      return;
    }

    final inPool = {for (final game in current.games) game.id};
    _rowsLeft(
      context,
      shownBefore: [
        for (final game in filterPool(previous.games, _filter)) game.id,
      ],
      shownAfter: [
        for (final game in filterPool(current.games, _filter)) game.id,
      ],
      kept: inPool,
      areas: _poolRowAreas,
      entryOf: OfferedCopyEntry.new,
      // Keeps the hand-off off a sub-tab that isn't shown (#945): with
      // Nominations chosen, a take-back that ends hands nothing on, and
      // focus stays where the user put it.
      list: EventGamesSection.pool,
      // A row whose Take back was pressed, however it was pressed: with
      // focus outside the row, to the next row's main action.
      handsOn: _armed.contains,
      fallback: _focusPoolHeader,
    );
    // Disarm what has left the pool.
    if (ended != null) _armed.remove(ended);
    _armed.removeWhere((id) => !inPool.contains(id));
  }

  /// The row of a write that ended with no change to the rows, its own read
  /// having failed, until the whole list's read that follows changes them
  /// ([nominationsChanged]).
  String? _unreadWrite;

  /// Whether a write that ended as [outcome] with no change to the rows read
  /// the whole list next: its row was to be read again, and that read failed.
  static bool _readsWhole(EventNominationsOutcome? outcome) =>
      switch (outcome) {
        VoteOutcome(result: VoteResult.done || VoteResult.closed) ||
        WithdrawOutcome(result: WithdrawResult.notWithdrawable) ||
        HostDecisionOutcome(result: HostDecisionResult.changed) ||
        ResolveOutcome(result: ResolveResult.changed) => true,
        _ => false,
      };

  /// Answers the nominations going from [previous] to [current], as the
  /// bloc emits them and before the frame that builds them (#517), from
  /// [context], the scope's, for the viewer [viewerId].
  ///
  /// A row that leaves the rows shown, filtered and sorted, while it holds
  /// focus, or as the write on it that was out ends, or as the whole list's
  /// read after that write does, where the write's own read of the row
  /// failed ([_readsWhole]), hands focus on once that frame has ended, as a
  /// pool row does ([poolChanged]): to the next row shown, else the one
  /// before it, in the same place among its controls (#946), its head from
  /// a head and the same choice of its vote from a choice, so the rows are
  /// worked through one after another; its head where it has no control
  /// there that can take focus. Where the write ended with focus outside
  /// the row, as a screen reader's activation leaves it, to the first of
  /// its controls past its head (#957), else its head. Where no row is
  /// left, to Filters, where it is built.
  /// The writes that can take their row away are a vote, as one voted on
  /// under "Not voted yet" leaves, a withdrawal, and a host's approval,
  /// rejection or close of a vote (#518), each of which changes the row's
  /// status, so it can leave a status filter, or finds it gone. The write's
  /// end arms it however it was pressed, so a screen reader's activation,
  /// which moves no input focus, is handed on too. It moves focus only while
  /// focus is free then: on nothing, on the page, or still on the row that
  /// left. A row that stays keeps its own focus. Only while the Nominations
  /// sub-tab is chosen (#945): on Pool the nominations' rows aren't built,
  /// so nothing is handed on. Nor while a quick look is open (#957), where
  /// each row that leaves notes where it left from instead
  /// ([focusAfterQuickLook]): a withdrawal and a host's decisions are sent
  /// from there alone (#946).
  void nominationsChanged(
    BuildContext context,
    EventNominationsState previous,
    EventNominationsState current, {
    required String? viewerId,
  }) {
    // The write on a row that was out before this change: the row it was
    // on. A nominate's id is the pool row's, and its row is a new one.
    final ended = switch (previous.writing) {
      (
        write: NominationWrite.vote ||
            NominationWrite.withdraw ||
            NominationWrite.approve ||
            NominationWrite.reject ||
            NominationWrite.resolve,
        :final id,
      ) =>
        id,
      _ => null,
    };
    if (identical(previous.nominations, current.nominations)) {
      // A write that ended with no change to the rows, where the row was to
      // be read again and that read failed, reads the whole list instead:
      // that read's change is still the write's (#517).
      if (current.writing != null) {
        _unreadWrite = null;
      } else if (ended != null && _readsWhole(current.outcome)) {
        _unreadWrite = ended;
      }
      return;
    }
    final written = ended ?? _unreadWrite;
    _unreadWrite = null;
    List<EventNomination> shown(List<EventNomination> all) => sortNominations(
      filterNominations(all, _nominationFilter, viewerId: viewerId),
      _nominationSort,
    );
    _rowsLeft(
      context,
      shownBefore: [
        for (final nomination in shown(previous.nominations)) nomination.id,
      ],
      shownAfter: [
        for (final nomination in shown(current.nominations)) nomination.id,
      ],
      kept: {for (final nomination in current.nominations) nomination.id},
      areas: _nominationAreas,
      entryOf: NominationEntry.new,
      list: EventGamesSection.nominations,
      // The row whose write ended, however it was sent: with focus outside
      // the row, past the next row's head, to its vote.
      handsOn: (id) => id == written,
      fallback: _focusNominationsHeader,
    );
  }

  /// Answers rows leaving one of the tab's lists, before the frame that
  /// builds the change, as [poolChanged] and [nominationsChanged] have it:
  /// [shownBefore] and [shownAfter] are the ids of the rows shown before and
  /// after, filtered and in order, [kept] every id the list still holds,
  /// whatever its filter keeps, and [areas] the nodes that hold its rows, by
  /// id. [entryOf] names what a row shows.
  ///
  /// Each row that leaves while a quick look is open notes where it left
  /// from, for [focusAfterQuickLook] (#957). Otherwise, while [list] is the
  /// sub-tab chosen (#945), the first row that leaves while focus is in it,
  /// or that [handsOn] names, hands focus on once that frame has ended, and
  /// only while focus is free then ([focusIsFree]): to the next row that
  /// stays, else the one before, its control in the place of the one that
  /// had focus, a head to the head, a main action to the main action,
  /// Nominate or Take back, and a vote's choice to the same choice, so the
  /// rows can be worked through one after another (#946); its head where it
  /// has no control there that can take focus. Where focus was outside the
  /// row, to the first of its controls past its head, else its head
  /// ([_inPlace]). Where no row is left, to [fallback]. The nodes of rows the
  /// list no longer holds are let go, and disposed of once their rows have
  /// gone too.
  void _rowsLeft<E extends EventGameEntry>(
    BuildContext context, {
    required List<String> shownBefore,
    required List<String> shownAfter,
    required Set<String> kept,
    required Map<String, FocusNode> areas,
    required E Function(String id) entryOf,
    required EventGamesSection list,
    required bool Function(String id) handsOn,
    required VoidCallback fallback,
  }) {
    final stays = shownAfter.toSet();
    final entriesAfter = [for (final id in shownAfter) entryOf(id)];

    // Where the row that hands focus on was among those that stay, and
    // where focus was among its controls, null where it wasn't in the row.
    int? at;
    int? place;
    FocusNode? held;
    // The rows before each one that stay.
    var stayed = 0;
    for (final id in shownBefore) {
      if (stays.contains(id)) {
        stayed++;
        continue;
      }
      // Every row that leaves while a quick look is open, whichever it
      // shows (#957).
      if (_quickLooks > 0) {
        _leftFrom[entryOf(id)] = _handOffOrder(entriesAfter, stayed);
      }
      if (at != null || section != list) continue;
      final area = areas[id];
      final focused = area?.hasFocus ?? false;
      if (!focused && !handsOn(id)) continue;
      at = stayed;
      place = focused ? _placeOfFocus(area!) : null;
      held = focused ? FocusManager.instance.primaryFocus : null;
    }

    // Let go the nodes of rows the list no longer holds, once their rows
    // have gone too.
    final keptEntries = {for (final id in kept) entryOf(id)};
    final gone = [
      for (final id in [...areas.keys])
        if (!kept.contains(id)) areas.remove(id)!,
      ..._releaseHeads((entry) => entry is E && !keptEntries.contains(entry)),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in gone) {
        node.dispose();
      }
      if (at == null || !context.mounted) return;
      // The quick look holds the focus, and hands it on as it closes.
      if (_quickLooks > 0) return;
      if (!focusIsFree(context, untouched: held)) return;
      for (final id in _handOffOrder(shownAfter, at)) {
        final target = _inPlace(
          _controlsOf(areas[id]),
          place,
          _rowHeads[entryOf(id)],
        );
        if (target == null) continue;
        target.requestFocus();
        return;
      }
      fallback();
    });
  }

  /// Hands focus to the pool's header, as a hand-off with no row left to
  /// take it does: to Offer games where it is built and enabled, ahead of
  /// the search field, whose keyboard would open over the games; else to
  /// the search field.
  void _focusPoolHeader() {
    final offer = offerArea.traversalDescendants.firstOrNull;
    if (offer != null) {
      offer.requestFocus();
      return;
    }
    focusSearch();
  }

  /// Hands focus to the nominations' Filters, as a hand-off with no row left
  /// to take it does. Only where it is built: a node asked while it isn't
  /// would take focus whenever it is built again, as the Games tab is shown
  /// again.
  void _focusNominationsHeader() {
    if (nominationsFiltersFocus.context?.mounted ?? false) {
      nominationsFiltersFocus.requestFocus();
    }
  }

  /// As a hand-off with no lineup row left to take focus does (#519): the
  /// Lineup sub-tab has no header control to take it, so focus stays on the
  /// page, as where the tab has nothing left to take focus
  /// ([EventGamesTabScope]).
  void _focusLineupHeader() {}

  @override
  void dispose() {
    _disposed = true;
    offerArea.dispose();
    peopleFocus.dispose();
    filtersFocus.dispose();
    clearFiltersFocus.dispose();
    searchArea.dispose();
    nominationsFiltersFocus.dispose();
    nominationsSortFocus.dispose();
    nominationsClearFiltersFocus.dispose();
    for (final node in _nominationAreas.values) {
      node.dispose();
    }
    for (final node in _lineupAreas.values) {
      node.dispose();
    }
    for (final node in _poolRowAreas.values) {
      node.dispose();
    }
    for (final node in _rowHeads.values) {
      node.dispose();
    }
    _clockTicks.dispose();
    super.dispose();
  }
}

/// Holds the Games tab's [EventGamesTabController] above the detail's
/// builder (#516), under the screen's `DefaultTabController` and its blocs.
///
/// It tells [onFirstShown] whenever the Games tab is chosen and hasn't yet
/// shown: as it is chosen; after the scope's first frame, as the screen's
/// location can open it on Games (#856); and on each of the detail's states, so
/// Games chosen while the detail loads shows once the detail is ready on the
/// server. An event only this device knows has no Games tab to show, and the
/// screen takes its tabs back to Details (#856), so Games doesn't wait on it
/// for the event to reach the server. [onFirstShown] reads the pool, the
/// nominations (#517) and the lineup (#519) and answers whether the tab
/// showed on a ready detail; only then is the tab
/// [EventGamesTabController.shown].
///
/// It watches the pool, and tells the controller each state as the pool
/// emits it, before the frame that builds it and on either tab: how the last
/// read ended ([EventGamesTabController.poolEmitted]), and a row leaving,
/// below. It watches the nominations the same way, for how their last read
/// ended ([EventGamesTabController.nominationsEmitted]), and a row leaving
/// the rows the nominations' filter keeps
/// ([EventGamesTabController.nominationsChanged]); and the lineup, for how
/// its last read ended ([EventGamesTabController.lineupEmitted]) and a row
/// leaving it ([EventGamesTabController.lineupChanged], #519).
///
/// ## A pool row's hand-off
///
/// It hears each change of the pool before the frame that builds it, while
/// a row that leaves is still built. When a row leaves while focus is
/// anywhere in it, or after its own Take back was pressed, focus goes, once
/// that frame has ended, to the next row shown, else the one before it, in
/// the same place (#946): to its head from a head, and to its main action,
/// Nominate or Take back, from a main action or a Take back pressed; to its
/// head where it has no such control built and enabled. Where no row is
/// left, to Offer games where it is built and enabled, else the search
/// field. A row leaves by its own take-back, or by a read or another user's
/// write. The press of Take back arms it however it came, so a screen
/// reader's activation, which moves no input focus, is handed on too, and
/// the reader's cursor follows. It moves focus only while focus is free
/// then: on nothing, on the page, or still on the control that left. A
/// press elsewhere meanwhile keeps its focus. A done take-back takes its
/// row away in the state that says so, so the row leaves as the take-back
/// ends, whatever the read after it does. Any take-back's end disarms it:
/// one that ends with its row still there, refused, failed or dropped,
/// hands nothing on, and nor does a later read that takes the row away
/// while focus is outside it.
///
/// Where the tab has nothing left to take focus, as when the pool turns
/// hidden and the header goes with the rows, nothing is focused: focus
/// stays on the page, where Flutter leaves it when a focused control goes.
///
/// Each list hands focus on only while its sub-tab is chosen (#945): a
/// take-back that ends while Nominations is shown, or a nominations write
/// that ends while Pool is, hands nothing on, then or when its sub-tab is
/// chosen again. Focus stays where the user put it, on the sub-tab chosen.
///
/// ## Quick looks
///
/// A row's quick look (#957) opens on the root navigator, outside the
/// scope, and reads the controller through [EventGamesTabScope.value]. While
/// one is open neither list hands focus on: the quick look holds the focus,
/// a take-back pressed in it arms the pool's hand-off as the row's does, and
/// a hand-off would take the focus from under the quick look's barrier.
/// Each row that leaves meanwhile
/// notes where it left from, and the quick look's close hands focus on from
/// there ([EventGamesTabController.focusAfterQuickLook]). The scope gives
/// the controller the screen's clock and its way to a game's page, which
/// the quick look reads ([now], [onOpenGame]), and the page tells it each
/// time that clock passes a boundary, so the quick look moves on with the
/// page ([EventGamesTabController.clockTicks]).
class EventGamesTabScope extends StatefulWidget {
  const EventGamesTabScope({
    required this.onFirstShown,
    required this.child,
    this.initialSection = EventGamesSection.lineup,
    this.now = DateTime.now,
    this.onOpenGame,
    super.key,
  });

  /// Reads the pool, the nominations and the lineup for the tab's first
  /// showing, and answers whether it showed on a ready detail. Asked again,
  /// as above, until it does. Given the scope's controller, which its
  /// context, above the scope's own, can't look up.
  final bool Function(
    BuildContext context,
    EventGamesTabController controller,
  )
  onFirstShown;

  final Widget child;

  /// The sub-tab the Games tab opens on (#945): the one the screen's
  /// location names, if it names one (#856). Read once, as the sub-tabs'
  /// controller is made.
  final EventGamesSection initialSection;

  /// The screen's clock, which the tab's quick looks read (#957):
  /// [EventGamesTabController.clock].
  final DateTime Function() now;

  /// Opens a game's page from a quick look's View game (#957):
  /// [EventGamesTabController.openGame].
  final OpenEventGame? onOpenGame;

  /// The controller of the scope above [context].
  static EventGamesTabController of(BuildContext context) => context
      .getInheritedWidgetOfExactType<_EventGamesTabInherited>()!
      .controller;

  /// The scope above [context], as a context of its own (#957): one that
  /// outlives what [context] belongs to, as a row that leaves while the
  /// quick look it opened is open.
  static BuildContext contextOf(BuildContext context) => context
      .getElementForInheritedWidgetOfExactType<_EventGamesTabInherited>()!;

  /// Provides [controller] to [child] alone, with nothing of the scope's
  /// own: for a pop-up the tab opens on the root navigator (#957), outside
  /// the scope, which reads the tab's state from it as the tab does.
  static Widget value({
    required EventGamesTabController controller,
    required Widget child,
  }) => _EventGamesTabInherited(controller: controller, child: child);

  @override
  State<EventGamesTabScope> createState() => _EventGamesTabScopeState();
}

class _EventGamesTabScopeState extends State<EventGamesTabScope>
    with TickerProviderStateMixin {
  final _controller = EventGamesTabController();
  TabController? _tabs;
  TabController? _sections;
  int _notifiedSection = 0;
  EventDetailBloc? _detailBloc;
  StreamSubscription<EventDetailState>? _detail;
  EventGamesBloc? _bloc;
  StreamSubscription<EventGamesState>? _pool;
  EventGamesState _last = const EventGamesState();
  EventNominationsBloc? _nominationsBloc;
  StreamSubscription<EventNominationsState>? _nominations;
  EventNominationsState _lastNominations = const EventNominationsState();
  EventLineupBloc? _lineupBloc;
  StreamSubscription<EventLineupState>? _lineup;
  EventLineupState _lastLineup = const EventLineupState();

  @override
  void initState() {
    super.initState();
    _useScreen();
    // The screen can open on Games (#856), with no tab change to say so.
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstShowing());
  }

  @override
  void didUpdateWidget(EventGamesTabScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _useScreen();
  }

  void _useScreen() =>
      _controller.useScreen(clock: widget.now, openGame: widget.onOpenGame);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tabs = DefaultTabController.of(context);
    if (tabs != _tabs) {
      _tabs?.removeListener(_firstShowing);
      _tabs = tabs..addListener(_firstShowing);
    }
    _useSections(
      BgeMotion.durationOf(context, BgeTokens.of(context).motionMedium),
    );
    final detail = context.read<EventDetailBloc>();
    if (detail != _detailBloc) {
      unawaited(_detail?.cancel());
      _detailBloc = detail;
      // Games chosen before the detail is ready shows once it is. This rests on
      // the bloc's first Ready of an event the server knows carrying
      // `reading: true`, as every open starts a read: the first showing then
      // reads none of the pool, the nominations and the lineup, and leaves
      // them to that read's end (the screen's `_readPoolAgain`), rather than
      // reading them beside it.
      _detail = detail.stream.listen((_) => _firstShowing());
    }
    final bloc = context.read<EventGamesBloc>();
    if (bloc != _bloc) {
      unawaited(_pool?.cancel());
      _bloc = bloc;
      _last = bloc.state;
      _controller.poolEmitted(bloc.state);
      // Heard before the frame that drops a row is built, while the row's
      // Take back is still built.
      _pool = bloc.stream.listen(_poolChanged);
    }
    final nominations = context.read<EventNominationsBloc>();
    if (nominations != _nominationsBloc) {
      unawaited(_nominations?.cancel());
      _nominationsBloc = nominations;
      _lastNominations = nominations.state;
      _controller.nominationsEmitted(nominations.state);
      // Heard before the frame that drops a row is built, while the row is
      // still built.
      _nominations = nominations.stream.listen(_nominationsChanged);
    }
    final lineup = context.read<EventLineupBloc>();
    if (lineup != _lineupBloc) {
      unawaited(_lineup?.cancel());
      _lineupBloc = lineup;
      _lastLineup = lineup.state;
      _controller.lineupEmitted(lineup.state);
      // Heard before the frame that drops a row is built, while the row is
      // still built.
      _lineup = lineup.stream.listen(_lineupChanged);
    }
  }

  /// Makes the sub-tabs' controller, and when [duration] differs from the
  /// one it has, replaces it by one at the same index, as
  /// `DefaultTabController` does, and lets the old one go after the frame.
  void _useSections(Duration duration) {
    final old = _sections;
    if (old != null && old.animationDuration == duration) return;
    final sections = TabController(
      length: EventGamesSection.values.length,
      initialIndex: old?.index ?? widget.initialSection.index,
      animationDuration: duration,
      vsync: this,
    );
    _sections = sections;
    _notifiedSection = sections.index;
    sections.addListener(_sectionChanged);
    if (old == null) {
      _controller.attachSections(sections);
      return;
    }
    old.removeListener(_sectionChanged);
    _controller.replaceSections(sections);
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  void _sectionChanged() {
    final index = _sections!.index;
    if (index == _notifiedSection) return;
    _notifiedSection = index;
    _controller.sectionChanged();
  }

  /// Asks [EventGamesTabScope.onFirstShown] for the Games tab's first
  /// showing, where Games is chosen and hasn't yet shown on a ready detail.
  void _firstShowing() {
    if (_controller.shown ||
        _tabs?.index != EventDetailTab.games.index ||
        !mounted) {
      return;
    }
    if (widget.onFirstShown(context, _controller)) _controller.markShown();
  }

  void _poolChanged(EventGamesState state) {
    final previous = _last;
    _last = state;
    _controller
      ..poolEmitted(state)
      ..poolOutcomeLanded(previous.outcome, state.outcome);
    if (!mounted) return;
    _controller.poolChanged(context, previous, state);
  }

  void _nominationsChanged(EventNominationsState state) {
    final previous = _lastNominations;
    _lastNominations = state;
    _controller
      ..nominationsEmitted(state)
      ..nominationsOutcomeLanded(previous.outcome, state.outcome);
    if (!mounted) return;
    final detail = context.read<EventDetailBloc>().state;
    _controller.nominationsChanged(
      context,
      previous,
      state,
      viewerId: detail is EventDetailReady
          ? detail.detail.attendance?.id
          : null,
    );
  }

  void _lineupChanged(EventLineupState state) {
    final previous = _lastLineup;
    _lastLineup = state;
    _controller.lineupEmitted(state);
    if (!mounted) return;
    final detail = context.read<EventDetailBloc>().state;
    _controller.lineupChanged(
      context,
      previous,
      state,
      dates: detail is EventDetailReady
          ? detail.detail.snapshot.occurrences
          : const [],
    );
  }

  @override
  void dispose() {
    _tabs?.removeListener(_firstShowing);
    _sections?.dispose();
    unawaited(_detail?.cancel());
    unawaited(_pool?.cancel());
    unawaited(_nominations?.cancel());
    unawaited(_lineup?.cancel());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _EventGamesTabInherited(controller: _controller, child: widget.child);
}

class _EventGamesTabInherited extends InheritedWidget {
  const _EventGamesTabInherited({
    required this.controller,
    required super.child,
  });

  final EventGamesTabController controller;

  @override
  bool updateShouldNotify(_EventGamesTabInherited oldWidget) =>
      controller != oldWidget.controller;
}

/// [EventGamesTabController.clockTicks]: a notifier the controller alone
/// tells.
class _ClockTicks extends ChangeNotifier {
  void tick() => notifyListeners();
}
