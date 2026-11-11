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
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_nominations_section.dart';
import 'package:events/src/widgets/event_pool_people_sheet.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_filters/game_filters.dart'
    show GameFilterChipLabel, InUseChips;
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
/// rows, and the nominations' state it was worked out from.
typedef _NominationsShown = ({
  EventNominationsBody body,
  List<EventNomination> rows,
  EventNominationsState state,
});

/// What the Games tab shows, worked out once per build (#517): the
/// Nominations section's body and rows, if it has a nominations' state, the
/// pool's, and the roster's names that both name people from. The screen
/// counts its rows for the page's `semanticChildCount`, and the tab draws
/// the same value, so the two can't disagree.
final class _GamesBody {
  const _GamesBody({
    required this.pool,
    required this.poolRows,
    required this.nominations,
    required this.names,
  });

  /// What the tab shows for [games] and [nominations] on [detail].
  factory _GamesBody.of(
    EventDetailReady detail,
    EventGamesState games,
    EventNominationsState? nominations,
    EventGamesTabController controller,
  ) {
    final (:body, :rows) = _poolOf(detail, games, controller);
    return _GamesBody(
      pool: body,
      poolRows: rows,
      nominations: nominations == null
          ? null
          : _nominationsOf(nominations, controller),
      names: {
        for (final row in detail.detail.snapshot.attendees ?? <EventAttendee>[])
          row.id: row.name,
      },
    );
  }

  /// What the pool shows under its header, if it has one.
  final _Body pool;

  /// The games the filter keeps, while [pool] is rows; none otherwise.
  final List<OfferedGame> poolRows;

  /// What the Nominations section shows, or null for no section.
  final _NominationsShown? nominations;

  /// The roster's names, by row id: none where it is withheld or not read.
  final Map<String, String?> names;

  /// How many nominations the section shows as rows: none while it shows a
  /// state. The pool's rows are counted on from them.
  int get nominationRowCount => switch (nominations) {
    (body: EventNominationsBody.rows, :final rows, state: _) => rows.length,
    _ => 0,
  };

  /// The rows the tab shows, the nominations' and the pool's: the page's
  /// `semanticChildCount` while it shows the tab.
  int get rowCount =>
      nominationRowCount + (pool == _Body.rows ? poolRows.length : 0);

  /// What the pool shows for [games] on [detail], and the rows when it shows
  /// rows.
  static ({_Body body, List<OfferedGame> rows}) _poolOf(
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

  /// What the Nominations section shows for [state] (#517): the
  /// nominations, else the state their read is drawn in
  /// ([EventGamesTabController.drawnNominationsLoad]). They need no roster,
  /// so they show wherever the pool can't.
  static _NominationsShown _nominationsOf(
    EventNominationsState state,
    EventGamesTabController controller,
  ) {
    final load = controller.drawnNominationsLoad(state);
    final body = load == EventNominationsLoad.hidden
        ? EventNominationsBody.hidden
        : state.nominations.isNotEmpty
        ? EventNominationsBody.rows
        : switch (load) {
            // Gone makes no claim of its own, as the pool's doesn't: the
            // event's read again settles it.
            EventNominationsLoad.idle ||
            EventNominationsLoad.loading ||
            EventNominationsLoad.gone => EventNominationsBody.loading,
            EventNominationsLoad.failed => EventNominationsBody.failed,
            EventNominationsLoad.loaded => EventNominationsBody.empty,
            EventNominationsLoad.hidden => EventNominationsBody.hidden,
          };
    return (
      body: body,
      rows: body == EventNominationsBody.rows ? state.nominations : const [],
      state: state,
    );
  }
}

/// The Games tab of an event's screen (#516): the games nominated for the
/// lineup ([EventNominationsSection], #517), then the games its attendees
/// offer to bring, one row per offered copy, under a header with Offer
/// games, a title search, a filter by person and "Not mine". The viewer's
/// own rows end with Take back.
///
/// Its slivers, as one group under the tab bar: the Nominations section,
/// where there is a nominations' state; then the pool's heading, "Games
/// pool", in every state, so heading navigation finds the pool as it finds
/// the section ([EventGamesTabHeading]); then the pool's header, then its
/// rows ([BgeKeyedSliverList], keyed by the offered game's id) or one state
/// in a [BgeStateSliver]. The header stays above every state but the wait
/// for a first answer (or for the event's read after the pool found it
/// gone, or to bring a roster not read) and the games being hidden. A roster
/// not read, as an event cached from the list has, is not hidden: it waits
/// for the event's read to bring it, and if that read fails, the tab says
/// it couldn't load the games, with Try again reading the event. The
/// nominations need no roster, so the section shows in every state of the
/// pool, hidden included.
///
/// What it shows is worked out once, as the tab is made, from the detail,
/// both states and the [controller] (#517). The page's `semanticChildCount`
/// is [rowCount], from that same value: the nominations' rows and the
/// pool's, the pool's counted on from the nominations' so a screen reader
/// numbers them as one list. How far a run of offers has got and how the
/// pool's last write went are [EventGamesFooter]'s, in the page's footer on
/// either tab; so is the stale-data banner after a failed read of games
/// still shown, while this tab is selected, and the nominations' own.
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
/// the field, which removes them ([InUseChips], the chips of Collection's
/// filters in use); a chip's own press hands focus to the chip in its
/// place, else the one before it, else People, while focus is free. While
/// the filter narrows a pool that has games, the count of what it keeps is
/// a live region.
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

  /// The screen's clock, as the page reads it this build.
  final DateTime now;

  /// Opens the Offer games page. Null builds no Offer games button.
  final OpenOfferGames? onOfferGames;

  /// What the tab shows, worked out once as it is made.
  final _GamesBody _body;

  /// Key on the Nominations section, so the pool's header after it keeps
  /// its place.
  static const _nominationsKey = ValueKey<String>('event_games.nominations');

  /// Key on the pool's heading, so it keeps its place as the header under
  /// it comes and goes.
  static const _poolHeadingKey = ValueKey<String>('event_games.pool_heading');

  /// Key on the header's sliver, so it keeps its state, and its chips their
  /// focus, as what is under it changes.
  static const _headerKey = ValueKey<String>('event_games.header');

  /// How many rows the tab shows: the nominations' and the pool's, none of
  /// either while it shows a state. The `semanticChildCount` of the page
  /// while it shows the tab.
  int get rowCount => _body.rowCount;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final body = _body.pool;
    final rows = _body.poolRows;
    final names = _body.names;
    final gate = offerGamesGate(detail);
    final viewerId = detail.detail.attendance?.id;
    // As the roster's controls are (#589): not while a detail read runs, the
    // screen's own request is out or the event is deleted, nor while another
    // of the pool's writes is out.
    final writable = !detail.reading && !acting && !games.busy;

    return SliverMainAxisGroup(
      slivers: [
        if (_body.nominations case final shown?)
          EventNominationsSection(
            key: _nominationsKey,
            body: shown.body,
            rows: shown.rows,
            detail: detail,
            state: shown.state,
            pool: games.games,
            // Before a read has answered, an empty pool says nothing of
            // what the viewer offers. While one is out, the last to end
            // stands, as the pool's own body has it.
            poolRead:
                games.games.isNotEmpty ||
                controller.drawnLoad(games) == EventGamesLoad.loaded,
            names: names,
            acting: acting,
            now: now,
          ),
        // In every state of the pool, as the section's is in every state of
        // its own, so heading navigation finds both (#517). No count: the
        // header's says how many games the filter keeps while it narrows,
        // and a second would say it twice.
        SliverToBoxAdapter(
          key: _poolHeadingKey,
          child: EventGamesTabHeading(title: l10n.eventsGamesPoolHeading),
        ),
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
            // Counted on from the nominations' rows above.
            semanticIndexOffset: _body.nominationRowCount,
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
