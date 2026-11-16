import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_detail_tabs.dart';
import 'package:events/src/widgets/event_game_filter_options.dart';
import 'package:events/src/widgets/event_game_quick_look.dart';
import 'package:events/src/widgets/event_game_row_head.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_nominations_section.dart';
import 'package:events/src/widgets/event_pool_people_sheet.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/held_spinner.dart';
import 'package:events/src/widgets/pool_row_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_filters/game_filters.dart'
    show
        GameFilterChipLabel,
        GameFiltersButton,
        GameFiltersInUse,
        InUseChips,
        gameFiltersInUseCount,
        showGameFilterSheet;
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// How the Games tab opens the Offer games page:
/// [EventDetailScreen.onOfferGames].
typedef OpenOfferGames = Future<List<OfferPick>?> Function(
  BuildContext context,
  OfferGamesArgs args,
);

/// What the pool shows under its header, if it has one.
enum _Body {
  /// The games aren't shown to this viewer, or the roster was read and
  /// withheld with no row of theirs on it, so there is nobody to read them
  /// for. No header.
  hidden,

  /// Waiting for the first answer, for the event's own read after the
  /// pool's found it gone, or for the event's read to bring a roster that
  /// hasn't been read. No header.
  loading,

  /// The read failed, with no games read before.
  failed,

  /// No roster has been read, and the event's read failed: as [failed], but
  /// Try again reads the event, since the pool has nobody to be read for.
  rosterFailed,

  /// Nobody has offered a game.
  empty,

  /// Games are offered, and the filter leaves none of them.
  noMatches,

  /// The games the filter keeps.
  rows,
}

/// What the Nominations section shows: its body, the rows when it shows
/// rows, filtered and sorted, and the nominations' state it was worked out
/// from.
typedef _NominationsShown = ({
  EventNominationsBody body,
  List<EventNomination> rows,
  EventNominationsState state,
});

/// What the pool shows: its body, and the games the filter keeps when it
/// shows rows, none otherwise.
typedef _PoolShown = ({_Body body, List<OfferedGame> rows});

/// What the Games tab shows, worked out once per build (#517): the sub-tab
/// shown (#945), that sub-tab's body and rows, and the roster's names that
/// both lists name people from. Only the sub-tab shown is worked out: the
/// Nominations section's where it is chosen, else the pool's. Its rows are
/// the ones its filter keeps, the nominations' in the order chosen. The
/// screen counts them for the page's `semanticChildCount`, and the tab draws
/// the same value, so the two can't disagree.
final class _GamesBody {
  const _GamesBody({required this.names, this.pool, this.nominations});

  /// What the tab shows for [games] and [nominations] on [detail], on the
  /// [controller]'s sub-tab. With no nominations' state it is the pool
  /// alone (#945).
  factory _GamesBody.of(
    EventDetailReady detail,
    EventGamesState games,
    EventNominationsState? nominations,
    EventGamesTabController controller,
  ) {
    final names = poolNames(detail.detail);
    if (nominations == null || controller.section == EventGamesSection.pool) {
      return _GamesBody(
        names: names,
        pool: _poolOf(detail, games, controller),
      );
    }
    return _GamesBody(
      names: names,
      nominations: _nominationsOf(detail, nominations, controller),
    );
  }

  /// What the pool shows, while the tab shows the pool; null otherwise.
  final _PoolShown? pool;

  /// What the Nominations section shows, while the tab shows it; null
  /// otherwise.
  final _NominationsShown? nominations;

  /// The roster's names, by row id: none where it is withheld or not read.
  final Map<String, String?> names;

  /// The rows the sub-tab shown holds, those its filter keeps, and none
  /// while it shows a state: the page's `semanticChildCount` while it shows
  /// the tab (#945).
  int get rowCount => switch ((pool, nominations)) {
    ((body: _Body.rows, :final rows), _) => rows.length,
    (_, (body: EventNominationsBody.rows, :final rows, state: _)) =>
      rows.length,
    _ => 0,
  };

  /// What the pool shows for [games] on [detail], and the rows when it shows
  /// rows.
  static _PoolShown _poolOf(
    EventDetailReady detail,
    EventGamesState games,
    EventGamesTabController controller,
  ) {
    final load = controller.drawnLoad(games);
    if (poolAttendeeIds(detail.detail).isEmpty) {
      // A roster read and withheld ([]) leaves this viewer nobody to read
      // for. One not read (null), as an event cached from the list has, says
      // nothing about the games: the event's read brings it. A read that
      // succeeded has ended a beat before the roster it wrote reaches the
      // screen, so only one that failed draws the failure.
      final body = detail.detail.snapshot.attendees != null
          ? _Body.hidden
          : detail.refreshFailed && !detail.reading
          ? _Body.rosterFailed
          : _Body.loading;
      return (body: body, rows: const []);
    }
    if (load == EventGamesLoad.hidden) {
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

  /// What the Nominations section shows for [state] on [detail] (#517):
  /// the nominations the [controller]'s filter keeps, in the order it holds
  /// ([filterNominations], then [sortNominations]), or no match, else the
  /// state their read is drawn in
  /// ([EventGamesTabController.drawnNominationsLoad]). They need no roster,
  /// so they show wherever the pool can't.
  static _NominationsShown _nominationsOf(
    EventDetailReady detail,
    EventNominationsState state,
    EventGamesTabController controller,
  ) {
    final load = controller.drawnNominationsLoad(state);
    if (load != EventNominationsLoad.hidden && state.nominations.isNotEmpty) {
      final rows = sortNominations(
        filterNominations(
          state.nominations,
          controller.nominationFilter,
          viewerId: detail.detail.attendance?.id,
        ),
        controller.nominationSort,
      );
      return (
        body: rows.isEmpty
            ? EventNominationsBody.noMatches
            : EventNominationsBody.rows,
        rows: rows,
        state: state,
      );
    }
    final body = switch (load) {
      // Gone makes no claim of its own, as the pool's doesn't: the event's
      // read again settles it.
      EventNominationsLoad.idle ||
      EventNominationsLoad.loading ||
      EventNominationsLoad.gone => EventNominationsBody.loading,
      EventNominationsLoad.failed => EventNominationsBody.failed,
      EventNominationsLoad.loaded => EventNominationsBody.empty,
      EventNominationsLoad.hidden => EventNominationsBody.hidden,
    };
    return (body: body, rows: const [], state: state);
  }
}

/// The Games tab of an event's screen (#516), in two sub-tabs (#945):
/// Nominations, the games nominated for the lineup ([EventNominationsSection],
/// #517), narrowed and ordered by its own filters and sort; and Pool, the games
/// its attendees offer to bring, one row per offered copy, under a header with
/// Offer games, a search, a filter by person, "Not mine" and the shared filter
/// sheet, as Offer games has it ([eventGameFilterOptions], #851).
///
/// Each pool row is compact (#946): its cover, its name with its subtitle
/// where it has one ([gameName], #851), one status line, and one main action.
/// The line says who brings it, and "Nominated" after that where the copy
/// supplies a live nomination and Nominate can't say it (#517, #947). The main
/// action is Nominate where the viewer is offered it ([nominateGate]), else
/// Take back on the viewer's own rows ([offerGamesGate]), and on every other
/// row where they may take back anyone's game ([canTakeBackAnyGame], #518).
/// The cover and the line are one button, which opens the copy's quick look
/// ([EventGameRowHead], #957): where it is played, what it supplies, Nominate
/// and Take back under the row's rules ([poolRowGates]), and View game. Take
/// back, the dialogs Take back and Nominate ask with, and their outcomes name
/// the game as the row does.
///
/// Its slivers, as one group under the tab bar: first the sub-tabs' bar
/// ([EventGamesSectionBar]), Material's secondary [TabBar], whose controller is
/// the [controller]'s [EventGamesTabController.sections]; then the chosen
/// sub-tab's slivers alone, which the bar swaps, keeping its own place, so
/// focus stays on the sub-tab chosen. Games opens on Nominations. Where there
/// is no nominations' state, the tab is the pool alone, with no bar.
///
/// Nominations is the Nominations section. Pool is the pool's header, then
/// its rows ([BgeKeyedSliverList], keyed by the offered game's id) or one
/// state in a [BgeStateSliver]. Neither has a heading of its own: each
/// sub-tab's label, said as it is chosen, names its list (#946). The header
/// stays above every state but the wait for a first answer (or for the
/// event's read after the pool found it gone, or to bring a roster not read)
/// and the games being hidden. A roster
/// not read, as an event cached from the list has, is not hidden: it waits
/// for the event's read to bring it, and if that read fails, the tab says
/// it couldn't load the games, with Try again reading the event. The
/// nominations need no roster, so the section shows in every state of the
/// pool, hidden included. Each sub-tab's filter, and the search typed in
/// the pool's, are the [controller]'s, so they outlive a switch to the
/// other sub-tab or to Details.
///
/// What it shows is worked out once, as the tab is made, from the detail,
/// the chosen sub-tab's state and the [controller] (#517). The page's
/// `semanticChildCount` is [rowCount], from that same value: the rows of
/// the sub-tab shown, numbered from its first. The line saying how many
/// games a run of offers is offering and how the pool's last write went are
/// [EventGamesFooter]'s, in the page's footer on either tab; so is the
/// stale-data banner of the sub-tab shown, after a failed read of what it
/// still shows, while this tab is selected.
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
/// Take back is held, inert, from its press until its take-back is over,
/// wherever it would otherwise be unavailable, so it keeps focus
/// ([TakeBackButton]). On the viewer's own row it sends at once; on
/// someone else's it asks first, naming the game and whose it is, since
/// only they can offer it again (#518). Then it waits for any running
/// detail read to end ([readEnded]), and sends only if the viewer may still
/// take that game back and it is still in the pool; otherwise nothing is
/// sent, and the footer says so. When the row leaves, focus is handed on as
/// [EventGamesTabScope] says.
///
/// Offer games opens the Offer games page ([onOfferGames]), and sends what
/// it answers the same way: once any running detail read has ended, as a
/// run of offers for the viewer's row, only if the viewer may still offer
/// games; otherwise nothing is sent, and the footer says so. It is held,
/// inert, from its press through the run, so the focus the page hands it
/// back as it closes stays on it.
///
/// Nominate (#517) is a direct write to the nominations, disabled offline
/// the same way. It is disabled, saying why, where the nominations' first
/// read failed or they aren't shown to the viewer, where a nominate's lost
/// answer couldn't be checked, where whoever brings the game isn't going, or
/// where the row is nominated already, or its game in the lineup, for
/// everything it could be; and with nothing to say while a detail read runs,
/// the screen's own request is out, a nominations write is out, or the
/// nominations' first read is out, before which nothing says what a row
/// supplies. On an
/// event of more than one date it asks first whether the nomination is for
/// the whole event or for one date still to come; otherwise it is for the
/// whole event. It sends as Take back does, once any running detail read
/// has ended, and only if it still may ([nominateGame]). It is held, inert,
/// from its press through its nomination, as Offer games is through its
/// run ([NominateButton]).
///
/// ## The filter
///
/// It narrows as it is changed, on the device ([filterPool]): the search, of
/// the title and the subtitle, on every edit; the people in *Whose games* as
/// each is chosen; and the facets of Filters' sheet as each is set (#851),
/// the sheet Offer games has ([showGameFilterSheet]): content type, platform
/// type, medium, publish year, players and play time, each of which can be
/// flipped. Each person chosen shows a chip under the field, which removes
/// them ([InUseChips], the chips of Collection's filters in use), and each
/// facet in use a chip under those ([GameFiltersInUse]). A chip's own press
/// hands focus to the chip in its place, else the one before it, else
/// People for a person's and Filters for a facet's, while focus is free.
/// *Whose games* and the sheet, closed, hand focus back to the button that
/// opened them. While the filter narrows a pool that has games, the count of
/// what it keeps is a live region.
class EventGamesTab extends StatelessWidget {
  EventGamesTab({
    required this.detail,
    required this.games,
    required this.controller,
    required this.acting,
    required this.now,
    this.nominations,
    this.onOfferGames,
    super.key,
  }) : _body = _GamesBody.of(detail, games, nominations, controller);

  final EventDetailReady detail;
  final EventGamesState games;

  /// The nominations' state (#517). Null shows no Nominations section.
  final EventNominationsState? nominations;

  /// The tab's own state, from the screen's [EventGamesTabScope].
  final EventGamesTabController controller;

  /// Whether the screen's own request is out, or the event is deleted.
  final bool acting;

  /// The screen's clock, read as the tab builds, and again as a nominate's
  /// dialog closes (#517).
  final DateTime Function() now;

  /// Opens the Offer games page. Null builds no Offer games button.
  final OpenOfferGames? onOfferGames;

  /// What the tab shows, worked out once as it is made.
  final _GamesBody _body;

  /// Key on the sliver that holds the sub-tabs' bar (#945).
  static const _sectionBarKey = ValueKey<String>('event_games.section_bar');

  /// Key on the Nominations section, so the pool's slivers never take its
  /// place as the sub-tabs swap (#945).
  static const _nominationsKey = ValueKey<String>('event_games.nominations');

  /// Key on the header's sliver, so it keeps its state, and its chips their
  /// focus, as what is under it changes.
  static const _headerKey = ValueKey<String>('event_games.header');

  /// How many rows the tab shows: those of the sub-tab shown (#945), none
  /// while it shows a state. The `semanticChildCount` of the page while it
  /// shows the tab.
  int get rowCount => _body.rowCount;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final now = this.now();
    final names = _body.names;
    final gate = offerGamesGate(detail);
    // Take back on someone else's row (#518), where the viewer may take
    // back anyone's game.
    final anyGame = canTakeBackAnyGame(detail);
    final viewerId = detail.detail.attendance?.id;
    // As the roster's controls are (#589): not while a detail read runs, the
    // screen's own request is out or the event is deleted, nor while another
    // of the pool's writes is out.
    final writable = !detail.reading && !acting && !games.busy;
    final nominations = this.nominations;

    return SliverMainAxisGroup(
      slivers: [
        // The sub-tabs' bar (#945), where there are two to show: with no
        // nominations' state the pool shows alone, with no bar. Keyed, so it
        // keeps its place, and the sub-tab chosen its focus, as the sub-tabs
        // swap under it. The controller is read as the tab is made: the
        // scope replaces it when the motion setting changes.
        if (nominations != null)
          SliverToBoxAdapter(
            key: _sectionBarKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EventGamesSectionBar(
                  key: EventDetailScreen.sectionBarKey,
                  controller: controller.sections,
                ),
                const BgeGap.lg(),
              ],
            ),
          ),
        if (_body.nominations case final shown?)
          EventNominationsSection(
            key: _nominationsKey,
            body: shown.body,
            rows: shown.rows,
            detail: detail,
            state: shown.state,
            controller: controller,
            pool: games.games,
            poolRead: controller.poolRead(games),
            acting: acting,
            now: now,
          ),
        if (_body.pool case (:final body, :final rows)) ...[
          if (body != _Body.hidden && body != _Body.loading)
            SliverToBoxAdapter(
              key: _headerKey,
              child: _PoolHeader(
                controller: controller,
                games: games,
                gate: gate,
                anyGame: anyGame,
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
            _Body.rosterFailed => BgeStateSliver(
              child: BgeErrorState(
                icon: Icons.cloud_off_outlined,
                title: l10n.eventsGamesFailedTitle,
                body: l10n.eventsGamesFailedBody,
                retryLabel: l10n.eventsRefreshRetry,
                retryProgressLabel: l10n.eventsRefreshInProgress,
                retryKey: EventDetailScreen.poolRetryKey,
                retrying: detail.refreshing,
                // The event's read brings the roster, whose end reads the pool.
                onRetry: () => context.read<EventDetailBloc>().add(
                  const EventDetailRetryRequested(),
                ),
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
                  focusNode: controller.clearFiltersFocus,
                  onPressed: () => controller.clearFilters(context),
                  child: Text(l10n.eventsGamesClearFilters),
                ),
              ),
            ),
            _Body.rows => BgeKeyedSliverList<OfferedGame>(
              items: rows,
              keyOf: (game) => EventDetailScreen.poolRowKey(game.id),
              itemBuilder: (context, game) {
                // The row's rules, which its quick look builds by too (#957).
                final gates = poolRowGates(
                  l10n,
                  game: game,
                  detail: detail,
                  games: games,
                  nominations: nominations,
                  controller: controller,
                  names: names,
                  acting: acting,
                  now: now,
                );
                final nominate = gates.nominate;
                final takeBack = gates.takeBack;
                return _PoolRow(
                  game: game,
                  area: controller.poolRowArea(game.id),
                  head: controller.rowHeadFocus(OfferedCopyEntry(game.id)),
                  who: gates.who,
                  nominated: gates.nominatedLine,
                  note: nominate?.notGoing,
                  // One main action (#946): Nominate where the viewer is
                  // offered it, else Take back where they may take it back.
                  // Take back beside Nominate is the quick look's.
                  action: switch ((nominate, takeBack)) {
                    (final nominate?, _) => NominateButton(
                      game: game,
                      unread: nominate.unread,
                      notGoing: nominate.notGoing,
                      already: nominate.already,
                      enabled: nominate.enabled,
                      runOver: nominate.runOver,
                      onPressed: () =>
                          nominateGame(context, game, clock: this.now),
                    ),
                    (null, final takeBack?) => TakeBackButton(
                      game: game,
                      inert: takeBack.inert,
                      enabled: takeBack.enabled,
                      runOver: takeBack.runOver,
                      onPressed: () {
                        // Armed by the press itself, however it came.
                        controller.armTakeBack(game.id);
                        return takeBackGame(
                          context,
                          controller,
                          game,
                          viewerId: viewerId,
                          names: names,
                        );
                      },
                    ),
                    (null, null) => null,
                  },
                );
              },
            ),
          },
        ],
      ],
    );
  }
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

/// The tab's header: Offer games, the search, People, "Not mine" and
/// Filters (#851), the people chosen, the facets in use, and the count while
/// the filter narrows a pool that has games. Each row of chips is always in
/// the tree, drawing nothing and spaced from above only while it shows a
/// chip, so that it is there to hand focus on after its last chip goes.
class _PoolHeader extends StatelessWidget {
  const _PoolHeader({
    required this.controller,
    required this.games,
    required this.gate,
    required this.anyGame,
    required this.viewerId,
    required this.names,
    required this.writable,
    required this.shown,
    this.onOfferGames,
  });

  final EventGamesTabController controller;
  final EventGamesState games;
  final OfferGamesGate gate;

  /// Whether the viewer may take back anyone's game (#518), so Take back
  /// is built on other people's rows too.
  final bool anyGame;
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
    final facets = gameFiltersInUseCount(
      filter.game,
      options: eventGameFilterOptions,
    );
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
        // Once for the tab, after Offer games where it is built: it, each
        // Nominate and each Take back carry it as their hint. Take back can
        // be built where Offer games isn't, on other people's rows (#518).
        if (offline && (gate != OfferGamesGate.hidden || anyGame)) ...[
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
            GameFiltersButton(
              count: facets,
              semanticsLabel: l10n.eventsGamesFiltersNamed(facets),
              focusNode: controller.filtersFocus,
              onPressed: () => unawaited(_openFilters(context)),
            ),
          ],
        ),
        // A chip per person chosen, which lets them go. Always in the tree,
        // drawing nothing without a chip, so that it is there to hand focus
        // to People after its last chip goes. Spaced from above only while
        // it shows chips.
        Padding(
          padding: EdgeInsets.only(
            top: filter.attendeeIds.isEmpty ? 0 : tokens.spaceSm,
          ),
          child: InUseChips<PoolFilter>(
            value: filter,
            chips: [
              for (final person in people)
                if (filter.attendeeIds.contains(person.id))
                  if (_chosenLabel(l10n, person, filter) case final label)
                    (
                      id: person.id,
                      key: EventDetailScreen.poolInUseKey(person.id),
                      label: label,
                      semanticsLabel: null,
                      removeLabel: l10n.eventsGamesPersonRemove(label),
                      without: filter.withoutPerson(person.id),
                    ),
            ],
            onRemove: (chip) => controller.choose(chip.id, chosen: false),
            onEmptied: controller.peopleFocus.requestFocus,
          ),
        ),
        // A chip per facet in use (#851), which clears it, under the
        // people's: the same rule, handing focus to Filters after its last.
        Padding(
          padding: EdgeInsets.only(top: facets > 0 ? tokens.spaceSm : 0),
          child: GameFiltersInUse(
            filter: filter.game,
            options: eventGameFilterOptions,
            onChanged: controller.setGameFilter,
            onEmptied: controller.filtersFocus.requestFocus,
          ),
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

  /// How the chip of [person], chosen in [filter], names them: as *Whose
  /// games* does, or, while the people chosen are left out, with "Not".
  String _chosenLabel(
    EventsLocalizations l10n,
    PoolPerson person,
    PoolFilter filter,
  ) => !filter.leaveOut
      ? person.label
      : person.id == viewerId
      ? l10n.eventsGamesPersonYouLeftOut
      // Mid-phrase, so the unnamed form for there.
      : l10n.eventsGamesPersonLeftOut(
          names[person.id] ?? l10n.eventsAttendeeSomeone,
        );

  /// Opens the Offer games page with the collection entries the viewer's
  /// own rows hold, so it can show them as already offered and pick none of
  /// them twice, and sends the games it answers with (#516). Completes true
  /// when a run was sent, and false when nothing was.
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
        attendeeIds: poolReadIds(state.detail),
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

  /// Opens the filter sheet on the pool's facets (#851), each change applied
  /// as it is made, and puts focus back on Filters once it has closed, where
  /// Filters is still built: a node asked while it isn't would take focus
  /// whenever it is built again.
  Future<void> _openFilters(BuildContext context) async {
    final focus = controller.filtersFocus;
    await showGameFilterSheet(
      context,
      initial: controller.filter.game,
      options: eventGameFilterOptions,
      onChanged: controller.setGameFilter,
    );
    if (focus.context?.mounted ?? false) focus.requestFocus();
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
                  icon: inert ? const HeldSpinner() : const Icon(Icons.add),
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

/// One offered copy (#516), compact (#946): its picture, its name, the
/// title with the subtitle where it has one ([gameName], #851), and one
/// status line, who brings it ([who]) and, where [nominated] says so,
/// "Nominated" after it (#947), spoken with a comma; as one button, which
/// opens the copy's quick look (#957, [EventGameRowHead]), focused through
/// [head]. Then its one main action, a node of its own ([action]): Nominate
/// where the viewer is offered it, else Take back where they may take it
/// back. Then [note], why Nominate can't be pressed, which its hint already
/// says. Where it is played, what it supplies, and Take back beside
/// Nominate, are the quick look's. The whole row is held by [area], so a row
/// that leaves can say it held focus ([EventGamesTabController.poolChanged]).
class _PoolRow extends StatelessWidget {
  const _PoolRow({
    required this.game,
    required this.area,
    required this.head,
    required this.who,
    required this.nominated,
    this.note,
    this.action,
  });

  final OfferedGame game;

  /// Holds the row ([EventGamesTabController.poolRowArea]).
  final FocusNode area;

  /// The focus of the row's head ([EventGamesTabController.rowHeadFocus]).
  final FocusNode head;

  /// Who brings it, as its status line says it.
  final String who;

  /// Whether its status line says Nominated: it supplies a live nomination
  /// and Nominate, which says so where it can't be pressed, isn't there to
  /// (#947).
  final bool nominated;

  /// Drawn under the main action, and left out of the semantics tree.
  final String? note;

  /// Its main action, Nominate or Take back, where it has one.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final action = this.action;
    final note = this.note;

    return Focus(
      focusNode: area,
      includeSemantics: false,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EventGameRowHead(
              key: EventDetailScreen.poolRowHeadKey(game.id),
              thumbnail: game.thumbnail,
              title: gameName(l10n, game.title, game.subtitle),
              entry: OfferedCopyEntry(game.id),
              focusNode: head,
              lines: [
                if (nominated)
                  Text(
                    l10n.eventsPoolStatusNominated(who),
                    key: EventDetailScreen.poolNominatedKey(game.id),
                    // The symbol between the two would be read out.
                    semanticsLabel: l10n.eventsPoolStatusNominatedSpoken(who),
                    style: quiet,
                  )
                else
                  Text(who, style: quiet),
              ],
            ),
            // Under the line, where it sat beside the picture before (#957).
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: BgeThumbnail.listExtent + tokens.spaceMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ?action,
                  if (note != null)
                    // Nominate's hint already says it.
                    ExcludeSemantics(
                      child: Text(
                        note,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
