import 'dart:async';

import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart' show EventNomination;
import 'package:ui/ui.dart';

/// What the Games tab keeps across the screen's rebuilds (#516): its filter,
/// whether it has been shown, the ids the pool was last asked with, how the
/// pool's last read ended and how the nominations' did (#517), the
/// nominations' own filter and order (#517), and the focus nodes a control
/// that leaves hands focus on to.
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
  EventGamesLoad? _settled;
  EventNominationsLoad? _nominationsSettled;

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

  void setQuery(String query) => _set(_filter.copyWith(query: query));

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

  /// Clears the search and the people, from Clear filters, which leaves
  /// with the state it sits in: the search field is emptied, and focus
  /// handed to People once the frame that builds it has ended, if focus is
  /// free then ([focusIsFree], from [context], with Clear filters counting
  /// as free if it held focus at the press). The press arms it however it
  /// came. Never to the search field: focus put on a text field opens the
  /// on-screen keyboard, over the games the user asked to see.
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
  /// scope's.
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

    int? left;
    FocusNode? held;
    for (final (index, game) in shownBefore.indexed) {
      if (stays.contains(game.id)) continue;
      final focused = _takeBackAreas[game.id]?.hasFocus ?? false;
      if (!focused && !_armed.contains(game.id)) continue;
      left = index;
      held = focused ? FocusManager.instance.primaryFocus : null;
      break;
    }

    // Disarm and let go what has left the pool, the nodes once their rows
    // have gone too.
    if (ended != null) _armed.remove(ended);
    final inPool = {for (final game in after) game.id};
    _armed.removeWhere((id) => !inPool.contains(id));
    final gone = [
      for (final MapEntry(:key, :value) in _takeBackAreas.entries)
        if (!inPool.contains(key)) (key, value),
    ];
    for (final (id, _) in gone) {
      _takeBackAreas.remove(id);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (_, node) in gone) {
        node.dispose();
      }
      if (left == null || !context.mounted) return;
      if (!focusIsFree(context, untouched: held)) return;
      // Where the row was among those that stay.
      final at = shownBefore
          .take(left)
          .where((game) => stays.contains(game.id))
          .length;
      // Each row that stays, the next first, then back from the one before:
      // the first whose Take back is built and enabled takes it. Only the
      // viewer's own rows have one, unless they may take back anyone's
      // (#518).
      final order = [
        ...shownAfter.skip(at),
        ...shownAfter.take(at).toList().reversed,
      ];
      for (final game in order) {
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
  /// decision's hand it to the row's lines.
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

    int? left;
    FocusNode? held;
    for (final (index, nomination) in shownBefore.indexed) {
      if (stays.contains(nomination.id)) continue;
      final focused = _nominationAreas[nomination.id]?.hasFocus ?? false;
      if (!focused && nomination.id != written) continue;
      left = index;
      held = focused ? FocusManager.instance.primaryFocus : null;
      break;
    }

    // Let go the nodes of nominations no longer held, once their rows have
    // gone too.
    final inSet = {for (final nomination in current.nominations) nomination.id};
    final gone = [
      for (final MapEntry(:key, :value) in _nominationAreas.entries)
        if (!inSet.contains(key)) (key, value),
    ];
    for (final (id, _) in gone) {
      _nominationAreas.remove(id);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (_, node) in gone) {
        node.dispose();
      }
      if (left == null || !context.mounted) return;
      if (!focusIsFree(context, untouched: held)) return;
      // Where the row was among those that stay.
      final at = shownBefore
          .take(left)
          .where((nomination) => stays.contains(nomination.id))
          .length;
      for (final nomination in [
        ...shownAfter.skip(at),
        ...shownAfter.take(at).toList().reversed,
      ]) {
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
    offerArea.dispose();
    peopleFocus.dispose();
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
    super.dispose();
  }
}

/// Holds the Games tab's [EventGamesTabController] above the detail's
/// builder (#516), under the screen's `DefaultTabController` and its blocs.
///
/// It tells [onFirstShown] the first time the Games tab is chosen, which
/// reads the pool and the nominations (#517) and answers whether the tab
/// showed on a ready detail; only then is the tab
/// [EventGamesTabController.shown].
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
class EventGamesTabScope extends StatefulWidget {
  const EventGamesTabScope({
    required this.onFirstShown,
    required this.child,
    super.key,
  });

  /// Reads the pool and the nominations for the tab's first showing, and
  /// answers whether it showed on a ready detail. Given the scope's
  /// controller, which its context, above the scope's own, can't look up.
  final bool Function(
    BuildContext context,
    EventGamesTabController controller,
  )
  onFirstShown;

  final Widget child;

  /// The controller of the scope above [context].
  static EventGamesTabController of(BuildContext context) => context
      .getInheritedWidgetOfExactType<_EventGamesTabInherited>()!
      .controller;

  @override
  State<EventGamesTabScope> createState() => _EventGamesTabScopeState();
}

class _EventGamesTabScopeState extends State<EventGamesTabScope> {
  final _controller = EventGamesTabController();
  TabController? _tabs;
  EventGamesBloc? _bloc;
  StreamSubscription<EventGamesState>? _pool;
  EventGamesState _last = const EventGamesState();
  EventNominationsBloc? _nominationsBloc;
  StreamSubscription<EventNominationsState>? _nominations;
  EventNominationsState _lastNominations = const EventNominationsState();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tabs = DefaultTabController.of(context);
    if (tabs != _tabs) {
      _tabs?.removeListener(_tabChanged);
      _tabs = tabs..addListener(_tabChanged);
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

  void _tabChanged() {
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
    _tabs?.removeListener(_tabChanged);
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
