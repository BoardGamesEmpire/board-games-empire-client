import 'dart:async';
import 'dart:math' as math;

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_pool_people_sheet.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_filters/game_filters.dart' show GameFilterChipLabel;
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// How the Games tab opens the Offer games page:
/// [EventDetailScreen.onOfferGames].
typedef OpenOfferGames = Future<List<OfferPick>?> Function(
  BuildContext context,
  OfferGamesArgs args,
);

/// What the Games tab shows under its header, if it has one.
enum _Body {
  /// The games aren't shown to this viewer, or there is nobody to read them
  /// for. No header.
  hidden,

  /// Waiting for the first answer, or for the event's own read after the
  /// pool's found it gone. No header.
  loading,

  /// The read failed, with no games read before.
  failed,

  /// Nobody has offered a game.
  empty,

  /// Games are offered, and the filter leaves none of them.
  noMatches,

  /// The games the filter keeps.
  rows,
}

/// What the tab shows for [games] on [detail], and the rows when it shows
/// rows.
({_Body body, List<OfferedGame> rows}) _bodyOf(
  EventDetailReady detail,
  EventGamesState games,
  EventGamesTabController controller,
) {
  final load = controller.drawnLoad(games);
  if (poolAttendeeIds(detail.detail).isEmpty || load == EventGamesLoad.hidden) {
    return (body: _Body.hidden, rows: const []);
  }
  if (games.games.isEmpty) {
    final body = switch (load) {
      // Gone makes no claim of its own: the screen reads the event again,
      // and that read's end reads the pool, which settles it. A 404 can
      // mean only that the roster read was stale, so "no games" could be
      // false.
      EventGamesLoad.idle ||
      EventGamesLoad.loading ||
      EventGamesLoad.gone => _Body.loading,
      EventGamesLoad.failed => _Body.failed,
      EventGamesLoad.loaded => _Body.empty,
      EventGamesLoad.hidden => _Body.hidden,
    };
    return (body: body, rows: const []);
  }
  final rows = filterPool(games.games, controller.filter);
  return (body: rows.isEmpty ? _Body.noMatches : _Body.rows, rows: rows);
}

/// The Games tab of an event's screen (#516): the games its attendees offer
/// to bring, one row per offered copy, under a header with Offer games, a
/// title search, a filter by person and "Not mine". The viewer's own rows
/// end with Take back.
///
/// Its slivers, as one group under the tab bar: the header, then the rows
/// ([BgeKeyedSliverList], keyed by the offered game's id) or one state in a
/// [BgeStateSliver]. The header stays above every state but the wait for
/// a first answer (or for the event's read after the pool found it gone)
/// and the games being hidden. The page's `semanticChildCount` is
/// [rowCount]. How far a run of offers has got, how the pool's last write
/// went, and the stale-data banner after a failed read of games still
/// shown, are [EventGamesFooter]'s, in the page's footer.
///
/// ## Writes
///
/// Offer games and Take back are direct writes, each disabled offline
/// through [BgeOnlineOnly], carrying the reason as its hint, with the
/// reason drawn once in the header, after Offer games where it is built.
/// Like the roster's controls they are disabled while a
/// detail read runs, whose answer landing after the write would show the
/// event as it was (#589), while the screen's own request is out or the
/// event is deleted ([acting]), and while another of the pool's writes is
/// out. The pool's own reads hold nothing back.
///
/// Take back is held, inert, while its own request is out, so it keeps
/// focus. Its press waits for any running detail read to end
/// ([readEnded]), then sends only if the viewer may still take games back
/// and the game is still in the pool; otherwise nothing is sent, and the
/// footer says so. When the row leaves, focus is handed on as
/// [EventGamesTabScope] says.
///
/// Offer games opens the Offer games page ([onOfferGames]), and sends what
/// it answers the same way: once any running detail read has ended, as a
/// run of offers for the viewer's row, only if the viewer may still offer
/// games; otherwise nothing is sent, and the footer says so. It is held,
/// inert, from its press through the run, so the focus the page hands it
/// back as it closes stays on it.
///
/// ## The filter
///
/// It narrows as it is changed: the search on every edit, and the people in
/// *Whose games* as each is chosen. Each person chosen shows a chip under
/// the field, which removes them; a chip's own press hands focus to the
/// chip in its place, else the one before it, else People, while focus is
/// free. While the filter narrows a pool that has games, the count of what
/// it keeps is a live region.
class EventGamesTab extends StatelessWidget {
  const EventGamesTab({
    required this.detail,
    required this.games,
    required this.acting,
    this.onOfferGames,
    super.key,
  });

  final EventDetailReady detail;
  final EventGamesState games;

  /// Whether the screen's own request is out, or the event is deleted.
  final bool acting;

  /// Opens the Offer games page. Null builds no Offer games button.
  final OpenOfferGames? onOfferGames;

  /// Key on the header's sliver, so it keeps its state, and its chips their
  /// focus, as what is under it changes.
  static const _headerKey = ValueKey<String>('event_games.header');

  /// How many rows the tab shows for [games] on [detail]: the
  /// `semanticChildCount` of the page while it shows the tab. None while it
  /// shows a state.
  static int rowCount(
    BuildContext context,
    EventDetailReady detail,
    EventGamesState games,
  ) {
    final (:body, :rows) = _bodyOf(
      detail,
      games,
      EventGamesTabScope.of(context),
    );
    return body == _Body.rows ? rows.length : 0;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final controller = EventGamesTabScope.of(context);
    final (:body, :rows) = _bodyOf(detail, games, controller);
    final gate = offerGamesGate(detail);
    final viewerId = detail.detail.attendance?.id;
    // As the roster's controls are (#589): not while a detail read runs, the
    // screen's own request is out or the event is deleted, nor while another
    // of the pool's writes is out.
    final writable = !detail.reading && !acting && !games.busy;
    final names = <String, String?>{
      for (final row in detail.detail.snapshot.attendees ?? <EventAttendee>[])
        row.id: row.name,
    };

    return SliverMainAxisGroup(
      slivers: [
        if (body != _Body.hidden && body != _Body.loading)
          SliverToBoxAdapter(
            key: _headerKey,
            child: _PoolHeader(
              controller: controller,
              games: games,
              gate: gate,
              viewerId: viewerId,
              names: names,
              writable: writable,
              shown: rows.length,
              onOfferGames: onOfferGames,
            ),
          ),
        switch (body) {
          _Body.hidden => BgeStateSliver(
            child: BgeEmptyState(
              icon: Icons.visibility_off_outlined,
              title: l10n.eventsGamesHiddenTitle,
            ),
          ),
          _Body.loading => BgeStateSliver(
            child: BgeLoadingState(label: l10n.eventsGamesLoading),
          ),
          _Body.failed => BgeStateSliver(
            child: BgeErrorState(
              icon: Icons.cloud_off_outlined,
              title: l10n.eventsGamesFailedTitle,
              body: l10n.eventsGamesFailedBody,
              retryLabel: l10n.eventsRefreshRetry,
              retryProgressLabel: l10n.eventsRefreshInProgress,
              retryKey: EventDetailScreen.poolRetryKey,
              retrying: games.refreshing,
              onRetry: () => retryEventGamesPool(context),
            ),
          ),
          _Body.empty => BgeStateSliver(
            child: BgeEmptyState(
              icon: Icons.casino_outlined,
              title: l10n.eventsGamesEmptyTitle,
              body: l10n.eventsGamesEmptyBody,
            ),
          ),
          _Body.noMatches => BgeStateSliver(
            child: BgeEmptyState(
              icon: Icons.search_off_outlined,
              title: l10n.eventsGamesNoMatchesTitle,
              action: OutlinedButton(
                key: EventDetailScreen.poolClearFiltersKey,
                onPressed: controller.clearFilters,
                child: Text(l10n.eventsGamesClearFilters),
              ),
            ),
          ),
          _Body.rows => BgeKeyedSliverList<OfferedGame>(
            items: rows,
            keyOf: (game) => EventDetailScreen.poolRowKey(game.id),
            itemBuilder: (context, game) {
              final own = viewerId != null && game.attendeeId == viewerId;
              return _PoolRow(
                game: game,
                who: own
                    ? l10n.eventsGamesYours
                    : l10n.eventsGamesTheirs(
                        names[game.attendeeId] ??
                            l10n.eventsAttendeeSomeoneStart,
                      ),
                takeBack: own && gate != OfferGamesGate.hidden
                    ? _TakeBackButton(
                        game: game,
                        area: controller.takeBackArea(game.id),
                        inert: games.takingBack == game.id,
                        enabled: writable,
                        onPressed: () {
                          // Armed by the press itself, however it came.
                          controller.armTakeBack(game.id);
                          unawaited(_takeBack(context, controller, game));
                        },
                      )
                    : null,
              );
            },
          ),
        },
      ],
    );
  }
}

/// Takes [game] back once any running detail read has ended (#516), for the
/// event, the viewer's row and the roster as the detail shows them then,
/// whose ids a reconcile can have moved (#499).
///
/// Nothing is sent if, by then, the viewer may no longer take games back,
/// the game isn't theirs, or it has left the pool: the page already shows
/// that, and the footer says the take-back was dropped, or a screen reader
/// would hear nothing happen. Whatever sends nothing disarms [controller]'s
/// hand-off from its Take back.
Future<void> _takeBack(
  BuildContext context,
  EventGamesTabController controller,
  OfferedGame game,
) async {
  // Read before anything is awaited: the row can leave meanwhile, and take
  // the context with it.
  final detail = context.read<EventDetailBloc>();
  final games = context.read<EventGamesBloc>();
  final state = await readEnded(detail);
  if (state is! EventDetailReady || games.isClosed) {
    controller.disarmTakeBack(game.id);
    return;
  }

  final viewer = state.detail.attendance;
  final inPool = games.state.games.any((shown) => shown.id == game.id);
  if (offerGamesGate(state) == OfferGamesGate.hidden ||
      viewer == null ||
      viewer.id != game.attendeeId ||
      !inPool) {
    controller.disarmTakeBack(game.id);
    games.add(
      EventGamesWriteDropped(EventGamesWrite.takeBack, title: game.title),
    );
    return;
  }
  // One write at a time; the bloc would ignore this one.
  if (games.state.busy) {
    controller.disarmTakeBack(game.id);
    return;
  }
  games.add(
    EventGameTakenBack(
      state.detail.snapshot.event.id,
      viewer.id,
      game,
      attendeeIds: poolAttendeeIds(state.detail),
    ),
  );
}

/// The people offering games, as *Whose games* and the chips list them: the
/// viewer first, then the roster's order, then anyone else in the pool's,
/// and anyone chosen whose games have left. Each named as their chip names
/// them.
List<PoolPerson> _poolPeople(
  EventsLocalizations l10n, {
  required List<OfferedGame> games,
  required Set<String> chosen,
  required String? viewerId,
  required Map<String, String?> names,
}) {
  final offering = {for (final game in games) game.attendeeId, ...chosen};
  final order = <String>[
    ?viewerId,
    ...names.keys,
    for (final game in games) game.attendeeId,
    ...chosen,
  ];
  final seen = <String>{};
  return [
    for (final id in order)
      if (offering.contains(id) && seen.add(id))
        (
          id: id,
          label: id == viewerId
              ? l10n.eventsGamesPersonYou
              : names[id] ?? l10n.eventsAttendeeSomeoneStart,
        ),
  ];
}

/// The tab's header: Offer games, the search, People and "Not mine", the
/// people chosen, and the count while the filter narrows a pool that has
/// games.
class _PoolHeader extends StatelessWidget {
  const _PoolHeader({
    required this.controller,
    required this.games,
    required this.gate,
    required this.viewerId,
    required this.names,
    required this.writable,
    required this.shown,
    this.onOfferGames,
  });

  final EventGamesTabController controller;
  final EventGamesState games;
  final OfferGamesGate gate;
  final String? viewerId;
  final Map<String, String?> names;

  /// Whether a write may be sent now, connection aside.
  final bool writable;

  /// How many rows the filter keeps.
  final int shown;
  final OpenOfferGames? onOfferGames;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final filter = controller.filter;
    final viewerId = this.viewerId;
    final open = onOfferGames;
    final people = _poolPeople(
      l10n,
      games: games.games,
      chosen: filter.attendeeIds,
      viewerId: viewerId,
      names: names,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (gate != OfferGamesGate.hidden && open != null) ...[
          _OfferGamesButton(
            area: controller.offerArea,
            notGoing: gate == OfferGamesGate.notGoing,
            enabled: gate == OfferGamesGate.open && writable,
            runOver:
                games.sending == null && games.load != EventGamesLoad.loading,
            onPressed: () => _offer(context, open),
          ),
          const BgeGap.md(),
        ],
        // Once for the tab, after Offer games where it is built: it and
        // each Take back carry it as their hint.
        if (offline && gate != OfferGamesGate.hidden) ...[
          const BgeOnlineOnlyNote(),
          const BgeGap.md(),
        ],
        Focus(
          focusNode: controller.searchArea,
          includeSemantics: false,
          child: BgeSearchField(
            // A new field, empty, only when the filter is cleared from
            // outside it.
            key: ValueKey<int>(controller.searchEpoch),
            fieldKey: EventDetailScreen.poolSearchKey,
            label: l10n.eventsGamesSearchLabel,
            clearLabel: l10n.eventsGamesSearchClear,
            initial: filter.query,
            onChanged: controller.setQuery,
          ),
        ),
        const BgeGap.sm(),
        Wrap(
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: EventDetailScreen.poolPeopleKey,
              focusNode: controller.peopleFocus,
              onPressed: people.isEmpty
                  ? null
                  : () => unawaited(_choosePeople(context, people)),
              icon: const Icon(Icons.people_outline),
              label: Text(l10n.eventsGamesPeople(filter.attendeeIds.length)),
            ),
            if (viewerId != null)
              FilterChip(
                key: EventDetailScreen.poolNotMineKey,
                label: GameFilterChipLabel(l10n.eventsGamesNotMine),
                selected: controller.isNotMine(viewerId),
                onSelected: (on) => controller.setNotMine(viewerId, on: on),
              ),
          ],
        ),
        _PeopleInUse(
          filter: filter,
          people: [
            for (final person in people)
              if (filter.attendeeIds.contains(person.id))
                (
                  id: person.id,
                  label: !filter.leaveOut
                      ? person.label
                      : person.id == viewerId
                      ? l10n.eventsGamesPersonYouLeftOut
                      : l10n.eventsGamesPersonLeftOut(person.label),
                ),
          ],
          onRemove: (id) => controller.choose(id, chosen: false),
          onEmptied: controller.peopleFocus.requestFocus,
        ),
        // With nothing offered there is nothing to count.
        if (filter.narrows && games.games.isNotEmpty) ...[
          const BgeGap.sm(),
          // A filter applied takes a live region on the text that changed.
          Semantics(
            key: EventDetailScreen.poolCountKey,
            container: true,
            liveRegion: true,
            child: Text(
              l10n.eventsGamesCount(shown, games.games.length),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
        const BgeGap.md(),
      ],
    );
  }

  /// Opens the Offer games page with the collection entries the viewer's
  /// own rows hold, so it can leave them out, and sends the games it
  /// answers with (#516). Completes true when a run was sent, and false
  /// when nothing was.
  ///
  /// No picks, or Back, send nothing and say nothing. With picks, the send
  /// waits for any running detail read to end ([readEnded]), then goes for
  /// the event, the viewer's row and the roster as the detail shows them
  /// then, whose ids a reconcile can have moved (#499), but only if the
  /// viewer may still offer games: otherwise nothing is sent, and the
  /// footer says the picks weren't offered, as Take back's drop does.
  Future<bool> _offer(BuildContext context, OpenOfferGames open) async {
    // Read before anything is awaited: the page covers the tab, and a
    // rebuild can take this context with the header.
    final detail = context.read<EventDetailBloc>();
    final pool = context.read<EventGamesBloc>();
    final viewerId = this.viewerId;
    final picks = await open(
      context,
      OfferGamesArgs(
        offeredCollectionIds: {
          for (final game in games.games)
            if (game.attendeeId == viewerId) game.collectionId,
        },
      ),
    );
    if (picks == null || picks.isEmpty || pool.isClosed) return false;

    final state = await readEnded(detail);
    if (state is! EventDetailReady || pool.isClosed) return false;
    final viewer = state.detail.attendance;
    if (offerGamesGate(state) != OfferGamesGate.open || viewer == null) {
      pool.add(const EventGamesWriteDropped(EventGamesWrite.offer));
      return false;
    }
    // One write at a time; the bloc would ignore this one.
    if (pool.state.busy) return false;
    pool.add(
      EventGamesOffered(
        state.detail.snapshot.event.id,
        viewer.id,
        picks,
        attendeeIds: poolAttendeeIds(state.detail),
      ),
    );
    return true;
  }

  /// Opens *Whose games*, and puts focus back on People once it has closed.
  Future<void> _choosePeople(
    BuildContext context,
    List<PoolPerson> people,
  ) async {
    final focus = controller.peopleFocus;
    await showEventPoolPeopleSheet(
      context,
      controller: controller,
      people: people,
    );
    if (focus.context != null) focus.requestFocus();
  }
}

/// Offer games (#516). Opens the Offer games page, and is held through the
/// run of offers the page answers with, as Add people is through its add.
///
/// The page hands the focus back to it as it closes, just before the run
/// goes out, and a disabled button can't hold focus (#607). So while it is
/// unavailable after its own press, through the run, it stays enabled and
/// ignores presses, saying it is offering. While it is unavailable for
/// another reason, another of the pool's writes, a detail read or the
/// screen's own request, it is disabled; offline too, through
/// [BgeOnlineOnly] (#49), and while the viewer has answered Not going, with
/// that reason as its hint and under it. The press is held through
/// [HeldPress], and forgotten as soon as the page answers with nothing to
/// send, the first time the button is built available after its run went
/// out, or once the run and the read of the pool after it are over
/// ([runOver]), whatever else is running then. The read of the pool after
/// its run holds it back no more than any read of the pool holds back the
/// tab's other controls: the run over, it is available through that read,
/// and a press then opens the page. A detail read still running as the run
/// ends, which the run didn't start, keeps it from being available, and
/// once [runOver] it is disabled then, as any control is.
class _OfferGamesButton extends StatefulWidget {
  const _OfferGamesButton({
    required this.area,
    required this.notGoing,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
  });

  /// Holds the button, so a hand-off can find it.
  final FocusNode area;
  final bool notGoing;

  /// Whether it may be pressed, connection aside: false while another
  /// of the pool's writes is out, a detail read runs, or the screen's own
  /// request is out.
  final bool enabled;

  /// Whether no run of offers is out and no read of the pool is running,
  /// as the read a run's end starts is: once a run went out, its own
  /// action is over, if the button wasn't let go sooner by being built
  /// available.
  final bool runOver;

  /// Opens the page and sends what it answers. Completes true when a run
  /// was sent, and false when nothing was.
  final Future<bool> Function() onPressed;

  @override
  State<_OfferGamesButton> createState() => _OfferGamesButtonState();
}

class _OfferGamesButtonState extends State<_OfferGamesButton>
    with HeldPress<_OfferGamesButton> {
  @override
  bool get heldActionOver => widget.runOver;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final notGoing = widget.notGoing;
    final reason = notGoing ? l10n.eventsGamesOfferNotGoing : null;
    // Offline, or not going, it is disabled, pressed or not: no press made
    // it so (#49).
    final inert = heldInert(
      available: widget.enabled && !notGoing && !offline,
      disabled: offline || notGoing,
    );
    final label = inert
        ? l10n.eventsGamesOfferInProgress
        : l10n.eventsGamesOffer;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Focus(
          focusNode: widget.area,
          includeSemantics: false,
          child: BgeOnlineOnly(
            showNote: false,
            child: Semantics(
              hint: reason,
              child: BgeInertButton(
                inert: inert,
                label: label,
                onPressed: (widget.enabled && !notGoing && !offline) || inert
                    ? () => unawaited(holdPress(widget.onPressed))
                    : null,
                builder: (context, focusNode, onPressed) => FilledButton.icon(
                  key: EventDetailScreen.offerGamesKey,
                  focusNode: focusNode,
                  onPressed: onPressed,
                  icon: inert ? const _HeldSpinner() : const Icon(Icons.add),
                  label: Text(label),
                ),
              ),
            ),
          ),
        ),
        if (reason != null) ...[
          const BgeGap.xs(),
          // Its hint already says it.
          ExcludeSemantics(
            child: Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A chip per person chosen, under the search field (#516). Tapping one, or
/// its remove button, lets them go.
///
/// A chip's own press arms a hand-off, however the press came: a key, a
/// pointer, or a screen reader's activation, which moves no input focus.
/// Once the header is built without it, focus goes to the chip that took
/// its place, else the one before it, else [onEmptied], but only while
/// focus is free: on nothing, on the page, or still on the chip that left.
/// So a chip removed by pointer while keyboard focus is on another moves
/// nothing, and neither does a hand-off once something else has taken
/// focus meanwhile.
///
/// It stays in the tree while it shows no chip, so a hand-off to
/// [onEmptied] has a widget to run from.
class _PeopleInUse extends StatefulWidget {
  const _PeopleInUse({
    required this.filter,
    required this.people,
    required this.onRemove,
    required this.onEmptied,
  });

  final PoolFilter filter;

  /// The people chosen, in order, each named as their chip says it.
  final List<PoolPerson> people;
  final ValueChanged<String> onRemove;
  final VoidCallback onEmptied;

  @override
  State<_PeopleInUse> createState() => _PeopleInUseState();
}

/// One chip's focus: `area` holds the whole chip, its remove button too, and
/// `chip` is the chip's own, which a hand-off focuses.
typedef _ChipFocus = ({FocusNode area, FocusNode chip});

class _PeopleInUseState extends State<_PeopleInUse> {
  final _focus = <String, _ChipFocus>{};

  /// A chip's removal, waiting for the filter without it: where the chip
  /// was, whom it named, and the node that held focus if the chip held it.
  ({int index, String id, FocusNode? node})? _pending;

  @override
  void didUpdateWidget(_PeopleInUse oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pending;
    if (pending == null || widget.filter == oldWidget.filter) return;
    _pending = null;
    if (widget.filter.attendeeIds.contains(pending.id)) return;
    // After the frame that builds the chips without it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(context, untouched: pending.node)) return;
      final ids = [for (final (:id, label: _) in widget.people) id];
      if (ids.isEmpty) {
        widget.onEmptied();
        return;
      }
      _focus[ids[math.min(pending.index, ids.length - 1)]]?.chip.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final (:area, :chip) in _focus.values) {
      area.dispose();
      chip.dispose();
    }
    super.dispose();
  }

  void _remove(String id, int index) {
    // Armed by the press. Focus still on the chip that left counts as free.
    final focused = _focus[id]?.area.hasFocus ?? false;
    _pending = (
      index: index,
      id: id,
      node: focused ? FocusManager.instance.primaryFocus : null,
    );
    widget.onRemove(id);
  }

  /// The focus nodes of the chips [ids] names, made for a chip as it comes
  /// and let go after the frame it leaves in.
  void _keepFocusOf(Set<String> ids) {
    for (final id in ids) {
      _focus.putIfAbsent(
        id,
        () => (
          area: FocusNode(
            debugLabel: 'Person chosen $id',
            canRequestFocus: false,
            skipTraversal: true,
          ),
          chip: FocusNode(debugLabel: 'Person chosen $id chip'),
        ),
      );
    }
    final gone = [
      for (final MapEntry(:key, :value) in _focus.entries)
        if (!ids.contains(key)) (key, value),
    ];
    if (gone.isEmpty) return;
    for (final (id, _) in gone) {
      _focus.remove(id);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final (_, (:area, :chip)) in gone) {
        area.dispose();
        chip.dispose();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final people = widget.people;
    _keepFocusOf({for (final (:id, label: _) in people) id});
    if (people.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(top: tokens.spaceSm),
      child: Wrap(
        spacing: tokens.spaceSm,
        runSpacing: tokens.spaceSm,
        children: [
          for (final (index, (:id, :label)) in people.indexed)
            Focus(
              focusNode: _focus[id]!.area,
              includeSemantics: false,
              child: InputChip(
                key: EventDetailScreen.poolInUseKey(id),
                focusNode: _focus[id]!.chip,
                label: GameFilterChipLabel(label),
                onPressed: () => _remove(id, index),
                onDeleted: () => _remove(id, index),
                deleteButtonTooltipMessage: l10n.eventsGamesPersonRemove(label),
              ),
            ),
        ],
      ),
    );
  }
}

/// One offered copy (#516): its picture, its title, where it is played, and
/// who brings it, as one node, then [takeBack] where the viewer may take it
/// back.
class _PoolRow extends StatelessWidget {
  const _PoolRow({required this.game, required this.who, this.takeBack});

  final OfferedGame game;

  /// Who brings it, as its last line says it.
  final String who;

  final Widget? takeBack;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final medium = switch (game.medium) {
      GameMedium.physical => l10n.eventsGamesMediumPhysical,
      GameMedium.digital => l10n.eventsGamesMediumDigital,
      null => null,
    };
    final takeBack = this.takeBack;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BgeThumbnail(url: game.thumbnail),
          const BgeGap.md(axis: Axis.horizontal),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(game.title, style: theme.textTheme.bodyLarge),
                      if (medium == null)
                        Text(game.platformName, style: quiet)
                      else
                        Text(
                          l10n.eventsGamesWhere(game.platformName, medium),
                          semanticsLabel: l10n.eventsGamesWhereSpoken(
                            game.platformName,
                            medium,
                          ),
                          style: quiet,
                        ),
                      Text(who, style: quiet),
                    ],
                  ),
                ),
                ?takeBack,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Take back on one of the viewer's rows (#516): a direct write, so
/// disabled offline through [BgeOnlineOnly], saying why as its hint. Inert
/// while its own request is out, so it keeps focus (#607); disabled while
/// another write is out or a detail read runs ([enabled]). Named for its
/// game to a screen reader.
class _TakeBackButton extends StatelessWidget {
  const _TakeBackButton({
    required this.game,
    required this.area,
    required this.inert,
    required this.enabled,
    required this.onPressed,
  });

  final OfferedGame game;

  /// Holds the button, so a row that leaves can say it held focus.
  final FocusNode area;

  /// Whether this row's take-back is out.
  final bool inert;

  /// Whether it may be pressed now, connection aside.
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    // Offline it is disabled, pressed or not: no press made it so (#49).
    final inert = this.inert && !offline;

    return Focus(
      focusNode: area,
      includeSemantics: false,
      child: BgeOnlineOnly(
        showNote: false,
        child: BgeInertButton(
          inert: inert,
          label: l10n.eventsGamesTakeBackNamed(game.title),
          onPressed: (enabled && !offline) || inert ? onPressed : null,
          builder: (context, focusNode, onPressed) => TextButton.icon(
            key: EventDetailScreen.poolTakeBackKey(game.id),
            focusNode: focusNode,
            onPressed: onPressed,
            icon: inert
                ? const _HeldSpinner()
                : const Icon(Icons.remove_circle_outline),
            label: Text(l10n.eventsGamesTakeBack),
          ),
        ),
      ),
    );
  }
}

/// A held button's icon while its write is out, Take back's or Offer
/// games': scaled with the label beside it, in the button's icon colour, as
/// the screen's other held buttons'.
class _HeldSpinner extends StatelessWidget {
  const _HeldSpinner();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: BgeTextScale.clampedOf(
      context,
    ).scale(BgeTokens.of(context).spaceMd),
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: IconTheme.of(context).color,
    ),
  );
}
