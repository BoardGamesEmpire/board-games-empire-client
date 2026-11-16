import 'dart:async';

import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:events/src/widgets/event_game_quick_look.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart' show CollectionFilter, EventNomination;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the Games tab keeps across the screen's rebuilds (#516): its sub-tabs'
/// controller (#945), its filter, whether it has been shown, the ids the pool
/// was last asked with, how the pool's last read ended and how the nominations'
/// did (#517), the nominations' own filter and order (#517), the focus
/// nodes a control that leaves hands focus on to, and what the tab's quick
/// looks reach the screen by (#957).
///
/// It notifies its listeners when the chosen sub-tab changes, once for each
/// change and as the change starts, and when the sub-tabs' controller is
/// replaced, so the screen's page, which listens to it, builds on the new one.
///
/// One per screen, held by [EventGamesTabScope] above the detail's builder,
/// beside the tab controller, so no read, write, clock tick or switch to the
/// Details tab under it forgets either filter, and the screen reads the pool
/// and the nominations after a detail read only once the tab has been shown.
class EventGamesTabController extends ChangeNotifier {
  PoolFilter _filter = const PoolFilter();
  NominationFilter _nominationFilter = const NominationFilter();
  NominationSort _nominationSort = NominationSort.newest;
  int _searchEpoch = 0;
  bool _shown = false;
  bool _disposed = false;
  EventGamesLoad? _settled;
  EventNominationsLoad? _nominationsSettled;

  late TabController _sections;

  /// The screen's clock, which a quick look reads as the tab does (#957).
  /// For the scope to set.
  DateTime Function() clock = DateTime.now;

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
  /// [EventDetailScreen.onOpenGame]. Null offers no View game. For the scope
  /// to set.
  OpenEventGame? openGame;

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

  /// Each row's Take back, where it is built, by the offered game's id.
  final Map<String, FocusNode> _takeBackAreas = {};

  /// The games whose Take back was pressed, and whose row leaving hands
  /// focus on.
  final Set<String> _armed = {};

  /// The node that holds offered game [id]'s Take back, made as it is first
  /// built and let go once the game leaves the pool.
  FocusNode takeBackArea(String id) => _takeBackAreas.putIfAbsent(
    id,
    () => FocusNode(
      debugLabel: 'Take back $id',
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
  /// let go once the entry leaves its list, as [takeBackArea]'s are.
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

  /// Hands focus on as the quick look of [entry] closes (#957), from
  /// [context], the scope's ([EventGamesTabScope.contextOf]), which outlives
  /// the row the quick look was opened from. To [entry]'s row head where its
  /// row is built. Where the row left while the quick look was open, to the
  /// head of the row now in its place, else of the nearest one before it,
  /// as [poolChanged] and [nominationsChanged] noted; else to the sub-tab's
  /// first header control: Filters for a nomination; for an offered copy,
  /// Offer games where it is built and enabled, else the search field.
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
        switch (entry) {
          // Offer games where it is built and enabled, as Take back's own
          // hand-off has it: the search field's keyboard would open over
          // the games.
          case OfferedCopyEntry():
            final offer = offerArea.traversalDescendants.firstOrNull;
            if (offer != null) {
              offer.requestFocus();
            } else {
              focusSearch();
            }
          // Only where it is built, as the nominations' own hand-off asks.
          case NominationEntry():
            if (nominationsFiltersFocus.context?.mounted ?? false) {
              nominationsFiltersFocus.requestFocus();
            }
        }
      })
      // A post-frame callback asks for no frame of its own.
      ..ensureVisualUpdate();
  }

  /// Whether [node]'s control is built.
  static bool _built(FocusNode node) => node.context?.mounted ?? false;

  /// [after] from [at]: the one there first, on to the last, then back from
  /// the one before it.
  static List<T> _from<T>(List<T> after, int at) => [
    ...after.skip(at),
    ...after.take(at).toList().reversed,
  ];

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

  /// Answers the pool going from [previous] to [current], as the bloc
  /// emits it and before the frame that builds it: Take back's hand-off (see
  /// "Take back's hand-off" on [EventGamesTabScope]), from [context], the
  /// scope's. Only while the Pool sub-tab is chosen (#945): on Nominations
  /// the pool's rows aren't built, so the change disarms what it ends and
  /// hands nothing on. Nor while a quick look is open (#957), where each row
  /// that leaves notes where it left from instead ([focusAfterQuickLook]).
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

    final before = previous.games;
    final after = current.games;
    final shownBefore = filterPool(before, _filter);
    final shownAfter = filterPool(after, _filter);
    final stays = {for (final game in shownAfter) game.id};
    final entriesAfter = [
      for (final game in shownAfter) OfferedCopyEntry(game.id),
    ];

    // Where the row that hands focus on was among those that stay.
    int? at;
    FocusNode? held;
    // The rows before each one that stay.
    var stayed = 0;
    for (final game in shownBefore) {
      if (stays.contains(game.id)) {
        stayed++;
        continue;
      }
      // Every row that leaves while a quick look is open, whichever it
      // shows (#957).
      if (_quickLooks > 0) {
        _leftFrom[OfferedCopyEntry(game.id)] = _from(entriesAfter, stayed);
      }
      // Keeps the hand-off off a sub-tab that isn't shown (#945): with
      // Nominations chosen, a take-back that ends hands nothing on, and
      // focus stays where the user put it.
      if (at != null || section != EventGamesSection.pool) continue;
      final focused = _takeBackAreas[game.id]?.hasFocus ?? false;
      if (!focused && !_armed.contains(game.id)) continue;
      at = stayed;
      held = focused ? FocusManager.instance.primaryFocus : null;
    }

    // Disarm and let go what has left the pool, the nodes once their rows
    // have gone too.
    if (ended != null) _armed.remove(ended);
    final inPool = {for (final game in after) game.id};
    _armed.removeWhere((id) => !inPool.contains(id));
    final gone = [
      for (final id in [..._takeBackAreas.keys])
        if (!inPool.contains(id)) _takeBackAreas.remove(id)!,
      ..._releaseHeads(
        (entry) =>
            entry is OfferedCopyEntry && !inPool.contains(entry.offeredGameId),
      ),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in gone) {
        node.dispose();
      }
      if (at == null || !context.mounted) return;
      // The quick look holds the focus, and hands it on as it closes.
      if (_quickLooks > 0) return;
      if (!focusIsFree(context, untouched: held)) return;
      // Each row that stays, the next first, then back from the one before:
      // the first whose Take back is built and enabled takes it. Only the
      // viewer's own rows have one, unless they may take back anyone's
      // (#518).
      for (final game in _from(shownAfter, at)) {
        final target =
            _takeBackAreas[game.id]?.traversalDescendants.firstOrNull;
        if (target != null) {
          target.requestFocus();
          return;
        }
      }
      // Only where it is built and enabled.
      final offer = offerArea.traversalDescendants.firstOrNull;
      if (offer != null) {
        offer.requestFocus();
        return;
      }
      focusSearch();
    });
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
  /// failed ([_readsWhole]), hands focus on once
  /// that frame has ended: to the first control of the next row shown that
  /// has one, else of the one before it, else Filters, where it is built.
  /// The writes that can take their row away are a vote, as one voted on
  /// under "Not voted yet" leaves, a withdrawal, and a host's approval,
  /// rejection or close of a vote (#518), each of which changes the row's
  /// status, so it can leave a status filter, or finds it gone. The write's
  /// end arms it however it was pressed, so a screen reader's activation,
  /// which moves no input focus, is handed on too. It moves focus only while
  /// focus is free then: on nothing, on the page, or still on the row that
  /// left. A row that stays keeps its own focus, as Withdraw's and a host's
  /// decision's hand it to the row's lines. Only while the Nominations
  /// sub-tab is chosen (#945): on Pool the nominations' rows aren't built,
  /// so nothing is handed on. Nor while a quick look is open (#957), where
  /// each row that leaves notes where it left from instead
  /// ([focusAfterQuickLook]).
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
    final shownBefore = shown(previous.nominations);
    final shownAfter = shown(current.nominations);
    final stays = {for (final nomination in shownAfter) nomination.id};
    final entriesAfter = [
      for (final nomination in shownAfter) NominationEntry(nomination.id),
    ];

    // Where the row that hands focus on was among those that stay.
    int? at;
    FocusNode? held;
    // The rows before each one that stay.
    var stayed = 0;
    for (final nomination in shownBefore) {
      if (stays.contains(nomination.id)) {
        stayed++;
        continue;
      }
      // Every row that leaves while a quick look is open, whichever it
      // shows (#957).
      if (_quickLooks > 0) {
        _leftFrom[NominationEntry(nomination.id)] = _from(
          entriesAfter,
          stayed,
        );
      }
      if (at != null || section != EventGamesSection.nominations) continue;
      final focused = _nominationAreas[nomination.id]?.hasFocus ?? false;
      if (!focused && nomination.id != written) continue;
      at = stayed;
      held = focused ? FocusManager.instance.primaryFocus : null;
    }

    // Let go the nodes of nominations no longer held, once their rows have
    // gone too.
    final inSet = {for (final nomination in current.nominations) nomination.id};
    final gone = [
      for (final id in [..._nominationAreas.keys])
        if (!inSet.contains(id)) _nominationAreas.remove(id)!,
      ..._releaseHeads(
        (entry) =>
            entry is NominationEntry && !inSet.contains(entry.nominationId),
      ),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in gone) {
        node.dispose();
      }
      if (at == null || !context.mounted) return;
      // The quick look holds the focus, and hands it on as it closes.
      if (_quickLooks > 0) return;
      if (!focusIsFree(context, untouched: held)) return;
      for (final nomination in _from(shownAfter, at)) {
        final target =
            _nominationAreas[nomination.id]?.traversalDescendants.firstOrNull;
        if (target != null) {
          target.requestFocus();
          return;
        }
      }
      // Only where it is built: a node asked while it isn't would take focus
      // whenever it is built again, as the Games tab is shown again.
      if (nominationsFiltersFocus.context?.mounted ?? false) {
        nominationsFiltersFocus.requestFocus();
      }
    });
  }

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
    for (final node in _takeBackAreas.values) {
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
/// for the event to reach the server. [onFirstShown] reads the pool and the
/// nominations (#517) and answers whether the tab showed on a ready detail;
/// only then is the tab [EventGamesTabController.shown].
///
/// It watches the pool, and tells the controller each state as the pool
/// emits it, before the frame that builds it and on either tab: how the last
/// read ended ([EventGamesTabController.poolEmitted]), and a row leaving,
/// below. It watches the nominations the same way, for how their last read
/// ended ([EventGamesTabController.nominationsEmitted]), and a row leaving
/// the rows the nominations' filter keeps
/// ([EventGamesTabController.nominationsChanged]).
///
/// ## Take back's hand-off
///
/// It hears each change of the pool before the frame that builds it, while
/// a row that leaves is still built. When a row whose Take back was
/// pressed leaves, or one whose Take back holds keyboard focus, focus
/// goes, once that frame has ended, to the Take back of the next row shown
/// that has one built and enabled, else of the nearest such row before it,
/// else Offer games where it is built and enabled, else the search field.
/// Only the viewer's own rows have Take back, unless they may take back
/// anyone's game (#518). The press arms it however it came, so a screen
/// reader's activation, which moves no input focus, is handed on too, and
/// the reader's cursor follows. It moves focus only while focus is free
/// then: on nothing, on the page, or still on the Take back that left. A
/// press elsewhere meanwhile keeps its focus. A done take-back takes its
/// row away in the state that says so, so the row leaves as the take-back
/// ends, whatever the read after it does. Any take-back's end disarms it:
/// one that ends with its row still there, refused, failed or dropped,
/// hands nothing on, and nor does a later read that takes the row away.
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
    this.initialSection = EventGamesSection.nominations,
    this.now = DateTime.now,
    this.onOpenGame,
    super.key,
  });

  /// Reads the pool and the nominations for the tab's first showing, and
  /// answers whether it showed on a ready detail. Asked again, as above,
  /// until it does. Given the scope's controller, which its context, above
  /// the scope's own, can't look up.
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

  @override
  void initState() {
    super.initState();
    _controller
      ..clock = widget.now
      ..openGame = widget.onOpenGame;
    // The screen can open on Games (#856), with no tab change to say so.
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstShowing());
  }

  @override
  void didUpdateWidget(EventGamesTabScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller
      ..clock = widget.now
      ..openGame = widget.onOpenGame;
  }

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
      // reads neither the pool nor the nominations, and leaves them to that
      // read's end (the screen's `_readPoolAgain`), rather than reading them
      // beside it.
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
    _controller.poolEmitted(state);
    if (!mounted) return;
    _controller.poolChanged(context, previous, state);
  }

  void _nominationsChanged(EventNominationsState state) {
    final previous = _lastNominations;
    _lastNominations = state;
    _controller.nominationsEmitted(state);
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

  @override
  void dispose() {
    _tabs?.removeListener(_firstShowing);
    _sections?.dispose();
    unawaited(_detail?.cancel());
    unawaited(_pool?.cancel());
    unawaited(_nominations?.cancel());
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
