import 'dart:async';

import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ui/ui.dart';

/// What the Games tab keeps across the screen's rebuilds (#516): its filter,
/// whether it has been shown, and the focus nodes a control that leaves
/// hands focus on to.
///
/// One per screen, held by [EventGamesTabScope] above the detail's builder,
/// beside the tab controller, so no read, write or clock tick under it
/// forgets the filter, and the screen reads the pool after a detail read
/// only once the tab has been shown.
class EventGamesTabController extends ChangeNotifier {
  PoolFilter _filter = const PoolFilter();
  int _searchEpoch = 0;
  bool _shown = false;
  EventGamesLoad? _settled;

  /// What the tab narrows the pool to.
  PoolFilter get filter => _filter;

  /// Moves on when the filter is cleared from outside the search field, so
  /// the field is built anew, empty. Never as the user types.
  int get searchEpoch => _searchEpoch;

  /// Whether the Games tab has shown on a ready detail at least once.
  bool get shown => _shown;

  /// Remembers that the Games tab has shown on a ready detail.
  void markShown() => _shown = true;

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

  /// Each own row's Take back, by the offered game's id.
  final Map<String, FocusNode> _takeBackAreas = {};

  /// The games whose Take back was pressed, and whose row leaving hands
  /// focus on.
  final Set<String> _armed = {};

  /// The armed games whose take-back ended done, waiting for the read that
  /// takes their rows away: true once that read has started. A read that
  /// was already running as the take-back ended reads the pool as it was.
  final Map<String, bool> _settling = {};

  /// The games whose take-back ended done over a pool whose last read had
  /// failed, disarmed until a read starts by the end of that frame. A read
  /// the session check stops before it goes out leaves such a pool's state
  /// as it was, and so is never seen to end.
  final Set<String> _rearm = {};

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

  void setQuery(String query) => _set(
    PoolFilter(
      query: query,
      attendeeIds: _filter.attendeeIds,
      leaveOut: _filter.leaveOut,
    ),
  );

  /// Chooses the person [id], or with [chosen] false, lets them go. Letting
  /// the last go turns leave-out off, so a choice made later never starts
  /// out left out.
  void choose(String id, {required bool chosen}) {
    final ids = {..._filter.attendeeIds};
    if (chosen) {
      ids.add(id);
    } else {
      ids.remove(id);
    }
    _set(
      PoolFilter(
        query: _filter.query,
        attendeeIds: ids,
        leaveOut: ids.isNotEmpty && _filter.leaveOut,
      ),
    );
  }

  /// Leaves the people chosen out, or keeps only them.
  void setLeaveOut({required bool leaveOut}) => _set(
    PoolFilter(
      query: _filter.query,
      attendeeIds: _filter.attendeeIds,
      leaveOut: _filter.attendeeIds.isNotEmpty && leaveOut,
    ),
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
    PoolFilter(
      query: _filter.query,
      attendeeIds: on ? {viewerId} : const {},
      leaveOut: on,
    ),
  );

  /// Clears the search and the people, empties the search field and puts
  /// focus in it, once the frame that builds it has ended.
  void clearFilters() {
    _searchEpoch++;
    _filter = const PoolFilter();
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => focusSearch());
  }

  /// Puts focus in the search field, where it is built.
  void focusSearch() =>
      searchArea.traversalDescendants.firstOrNull?.requestFocus();

  void _set(PoolFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    notifyListeners();
  }

  /// The load the tab draws [state] as: its own, or while a read is out, the
  /// last one a read ended with, so a read again neither flashes a spinner
  /// over an answer nor announces it. Before any read has ended it is idle.
  EventGamesLoad drawnLoad(EventGamesState state) {
    switch (state.load) {
      case EventGamesLoad.idle || EventGamesLoad.loading:
        return _settled ?? EventGamesLoad.idle;
      case final settled:
        return _settled = settled;
    }
  }

  /// Answers the pool going from [previous] to [current], as the bloc
  /// emits it and before the frame that builds it: Take back's hand-off (see
  /// "Take back's hand-off" on [EventGamesTabScope]), from [context], the
  /// scope's, for the viewer [viewerId].
  void poolChanged(
    BuildContext context,
    EventGamesState previous,
    EventGamesState current, {
    required String? viewerId,
  }) {
    // A take-back that ended with its row still there hands nothing on. One
    // that ended done waits for the read after it.
    final ended = previous.takingBack;
    if (ended != null && current.takingBack == null) {
      if (current.outcome?.result != EventGamesResult.done) {
        _armed.remove(ended);
      } else if (current.load == EventGamesLoad.failed) {
        // The read after it may end with no change to see: disarmed unless
        // it starts before this frame is out.
        _armed.remove(ended);
        _rearm.add(ended);
        WidgetsBinding.instance
          ..addPostFrameCallback((_) => _rearm.remove(ended))
          ..ensureVisualUpdate();
      } else {
        _settling[ended] = false;
      }
    }
    _readMoved(previous, current);
    if (identical(previous.games, current.games)) return;

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
    final inPool = {for (final game in after) game.id};
    _armed.removeWhere((id) => !inPool.contains(id));
    _settling.removeWhere((id, _) => !inPool.contains(id));
    _rearm.removeWhere((id) => !inPool.contains(id));
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
      final own = [
        for (final game in shownAfter.skip(at))
          if (game.attendeeId == viewerId) game,
        for (final game in shownAfter.take(at).toList().reversed)
          if (game.attendeeId == viewerId) game,
      ];
      for (final game in own) {
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

  /// Follows the reads of the pool from [previous] to [current] for the
  /// take-backs that ended done ([_settling]). The first read to start
  /// after one ended is the one that takes its row away. Once that read
  /// has ended with the row still in the pool, because it failed, or the
  /// server still lists the game, the hand-off is disarmed: a later read
  /// that takes the row away, a retry or a detail refresh minutes on, moves
  /// no focus nobody asked for.
  void _readMoved(EventGamesState previous, EventGamesState current) {
    const loading = EventGamesLoad.loading;
    final was = previous.load;
    final now = current.load;
    if (now == loading && was != loading) {
      // The read after a take-back over a failed pool has started: armed
      // again, for that read.
      for (final id in _rearm) {
        _armed.add(id);
        _settling[id] = true;
      }
      _rearm.clear();
    }
    if (_settling.isEmpty) return;
    if (now == loading) {
      if (was != loading) _settling.updateAll((_, _) => true);
      return;
    }
    // A read ends from loading, or straight to failed when the session
    // stops it before it goes out.
    final readEnded =
        was == loading ||
        (now == EventGamesLoad.failed && was != EventGamesLoad.failed);
    if (!readEnded) return;
    final inPool = {for (final game in current.games) game.id};
    _settling.removeWhere((id, started) {
      // The read that was running as the take-back ended: the next is its.
      if (!started && was == loading) return false;
      if (inPool.contains(id)) _armed.remove(id);
      return true;
    });
  }

  @override
  void dispose() {
    offerArea.dispose();
    peopleFocus.dispose();
    searchArea.dispose();
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
/// reads the pool and answers whether the tab showed on a ready detail; only
/// then is the tab [EventGamesTabController.shown].
///
/// ## Take back's hand-off
///
/// It watches the pool, and hears each change before the frame that builds
/// it, while a row that leaves is still built. When a row whose Take back
/// was pressed leaves, or one whose Take back holds keyboard focus, focus
/// goes, once that frame has ended, to the next own row's Take back among
/// the rows shown, else the previous one's, else Offer games where it is
/// built and enabled, else the search field. The press arms it however it
/// came, so a screen reader's activation, which moves no input focus, is
/// handed on too, and the reader's cursor follows. It moves focus only
/// while focus is free then: on nothing, on the page, or still on the Take
/// back that left. A press elsewhere meanwhile keeps its focus. A
/// take-back that ends with its row still there, refused, failed or
/// dropped, disarms it. So does one that ends done, once the read after it
/// has ended with the row still in the pool, failed or not: a later read
/// that takes the row away hands nothing on. Over a pool whose last read
/// failed, the read after a take-back can end with nothing changed to see,
/// when the session check stops it, so there the hand-off is disarmed as
/// the take-back ends, and armed again only if a read starts before that
/// frame is out. Where there is no session check, on native, the read
/// starts within the frame. On the web the session check usually outlasts
/// it, so there a Take back pressed by a screen reader's activation or a
/// pointer, over a pool whose last read had failed, usually hands nothing
/// on when its row goes: focus stays on the page. A Take back pressed by
/// keyboard holds focus, and that is handed on either way, as it doesn't
/// depend on the arm.
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

  /// Reads the pool for the tab's first showing, and answers whether it
  /// showed on a ready detail.
  final bool Function(BuildContext context) onFirstShown;

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
      // Heard before the frame that drops a row is built, while the row's
      // Take back is still built.
      _pool = bloc.stream.listen(_poolChanged);
    }
  }

  void _tabChanged() {
    if (_controller.shown ||
        _tabs?.index != EventDetailTab.games.index ||
        !mounted) {
      return;
    }
    if (widget.onFirstShown(context)) _controller.markShown();
  }

  void _poolChanged(EventGamesState state) {
    final previous = _last;
    _last = state;
    if (!mounted) return;
    final detail = context.read<EventDetailBloc>().state;
    _controller.poolChanged(
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
