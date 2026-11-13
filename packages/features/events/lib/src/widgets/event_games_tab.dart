import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/confirm_dialog.dart';
import 'package:events/src/widgets/event_game_filter_options.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/event_nominations_section.dart';
import 'package:events/src/widgets/event_pool_people_sheet.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/nominate_scope_dialog.dart';
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

/// What the Games tab shows, worked out once per build (#517): the
/// Nominations section's body and rows, if it has a nominations' state, the
/// pool's, and the roster's names that both name people from. Each list's
/// rows are the ones its filter keeps, the nominations' in the order chosen.
/// The screen counts its rows for the page's `semanticChildCount`, and the
/// tab draws the same value, so the two can't disagree.
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
          : _nominationsOf(detail, nominations, controller),
      names: poolNames(detail.detail),
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

  /// How many nominations the section shows as rows, those its filter
  /// keeps: none while it shows a state. The pool's rows are counted on from
  /// them.
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

/// The Games tab of an event's screen (#516): the games nominated for the
/// lineup ([EventNominationsSection], #517), narrowed and ordered by its own
/// filters and sort, then the games its attendees offer to bring, one row
/// per offered copy, under a header with Offer games, a search, a filter by
/// person, "Not mine" and the shared filter sheet, as Offer games has it
/// ([eventGameFilterOptions], #851). Each row names its game with
/// its subtitle where it has one ([gameName], #851), as do its Take back and
/// Nominate, the dialogs they ask with, and their outcomes. A
/// row that supplies a live nomination says "Nominated" (#517). Each row
/// ends with Nominate where the viewer is offered it ([nominateGate]), and
/// the viewer's own rows with Take back ([offerGamesGate]); every other row
/// too where the viewer may take back anyone's game ([canTakeBackAnyGame],
/// #518).
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
/// numbers them as one list. The line saying how many games a run of offers
/// is offering and how the pool's last write went are [EventGamesFooter]'s,
/// in the page's footer on either tab; so is the stale-data banner after a
/// failed read of games still shown, while this tab is selected, and the
/// nominations' own.
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
/// ([_TakeBackButton]). On the viewer's own row it sends at once; on
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
/// has ended, and only if it still may ([_nominate]). It is held, inert,
/// from its press through its nomination, as Offer games is through its
/// run ([_NominateButton]).
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
    final now = this.now();
    final body = _body.pool;
    final rows = _body.poolRows;
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
    final nominated = nominations?.nominations ?? const <EventNomination>[];
    // Nominate (#517), on every row, where the viewer is offered it.
    final nominating =
        nominations != null && nominateGate(detail) == NominateGate.open;
    final scopes = nominating
        ? _nominateScopes(detail.detail, now: now)
        : const <_NominateScope>[];
    // As the tab's other writes are, and not while another nominations
    // write is out. Nor before the nominations are known: none held before a
    // read has answered says nothing of what a row supplies, and nothing
    // stops a second nomination of a row for one choice (backend#1214).
    final mayNominate =
        nominations != null &&
        !detail.reading &&
        !acting &&
        !nominations.busy &&
        _nominationsKnown(nominations, controller);
    // Why Nominate waits with no nominations to go on, where the wait won't
    // end by itself (#517): a first read that failed, nominations this
    // viewer isn't shown, or a nominate's lost answer whose read failed. A
    // read that is still out says nothing.
    final drawn = nominations == null
        ? null
        : controller.drawnNominationsLoad(nominations);
    final unread = nominations == null
        ? null
        : nominations.settling
        ? switch (drawn) {
            EventNominationsLoad.failed => l10n.eventsNominateUnsettled,
            EventNominationsLoad.hidden => l10n.eventsNominationsHiddenTitle,
            _ => null,
          }
        : nominations.nominations.isNotEmpty
        ? null
        : switch (drawn) {
            EventNominationsLoad.failed => l10n.eventsNominationsFailedTitle,
            EventNominationsLoad.hidden => l10n.eventsNominationsHiddenTitle,
            _ => null,
          };

    return SliverMainAxisGroup(
      slivers: [
        if (_body.nominations case final shown?)
          EventNominationsSection(
            key: _nominationsKey,
            body: shown.body,
            rows: shown.rows,
            detail: detail,
            state: shown.state,
            controller: controller,
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
            // Counted on from the nominations' rows above.
            semanticIndexOffset: _body.nominationRowCount,
            itemBuilder: (context, game) {
              final own = viewerId != null && game.attendeeId == viewerId;
              // In the second person on the viewer's own rows, as the row's
              // third line is.
              final notGoing =
                  !nominating || !_supplierNotGoing(detail.detail, game)
                  ? null
                  : own
                  ? l10n.eventsNominateYouNotGoingHint
                  : l10n.eventsNominateSupplierNotGoingHint;
              final name = names[game.attendeeId];
              return _PoolRow(
                game: game,
                who: own
                    ? l10n.eventsGamesYours
                    : l10n.eventsGamesTheirs(
                        name ?? l10n.eventsAttendeeSomeoneStart,
                      ),
                nominated: suppliesLive(game, nominated),
                note: notGoing,
                nominate: nominating
                    ? _NominateButton(
                        game: game,
                        unread: unread,
                        notGoing: notGoing,
                        already: _alreadyTaken(l10n, [
                          for (final each in scopes)
                            nominateTaken(game, nominated, scope: each.scope),
                        ]),
                        enabled: mayNominate,
                        runOver: !nominations.busy,
                        onPressed: () =>
                            _nominate(context, game, clock: this.now),
                      )
                    : null,
                takeBack: (own ? gate != OfferGamesGate.hidden : anyGame)
                    ? _TakeBackButton(
                        game: game,
                        area: controller.takeBackArea(game.id),
                        inert: games.takingBack == game.id,
                        enabled: writable,
                        runOver: !games.busy,
                        onPressed: () {
                          // Armed by the press itself, however it came.
                          controller.armTakeBack(game.id);
                          return _takeBack(
                            context,
                            controller,
                            game,
                            viewerId: viewerId,
                            names: names,
                          );
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
/// whose ids a reconcile can have moved (#499). Completes true when the
/// take-back was sent, and false when nothing was: Keep it, or as below.
///
/// Whose game it is comes from the row's attendee: the viewer's own, where
/// it is their row [viewerId], goes at once. Someone else's asks first, as a
/// destructive action, naming the game and whoever offered it from [names],
/// the roster's names, as the row does ([gameName], #851): only they can
/// offer it again (#518). It then goes for the row's attendee as the pool
/// holds it then.
///
/// Nothing is sent if, by then, the viewer may no longer take that game
/// back (their own: [offerGamesGate]; anyone else's: [canTakeBackAnyGame]),
/// their own game is no longer theirs, or it has left the pool: the page
/// already shows that, and the footer says the take-back was dropped, or a
/// screen reader would hear nothing happen. Whatever sends nothing disarms
/// [controller]'s hand-off from its Take back.
Future<bool> _takeBack(
  BuildContext context,
  EventGamesTabController controller,
  OfferedGame game, {
  required String? viewerId,
  required Map<String, String?> names,
}) async {
  // Read before anything is awaited: the row can leave meanwhile, and take
  // the context with it, and the dialog covers it.
  final l10n = EventsLocalizations.of(context);
  final detail = context.read<EventDetailBloc>();
  final games = context.read<EventGamesBloc>();
  final own = viewerId != null && game.attendeeId == viewerId;
  if (!own) {
    final offeredBy = names[game.attendeeId] ?? l10n.eventsAttendeeSomeone;
    final confirmed = await showConfirmDialog(
      context,
      title: l10n.eventsTakeBackTheirsConfirmTitle(
        gameName(l10n, game.title, game.subtitle),
        offeredBy,
      ),
      body: l10n.eventsTakeBackTheirsConfirmBody,
      keepLabel: l10n.eventsTakeBackTheirsConfirmKeep,
      confirmLabel: l10n.eventsTakeBackTheirsConfirm,
      destructive: true,
      keepKey: EventDetailScreen.poolTakeBackKeepKey,
      confirmKey: EventDetailScreen.poolTakeBackConfirmKey,
    );
    if (!confirmed || games.isClosed) {
      controller.disarmTakeBack(game.id);
      return false;
    }
  }
  final state = await readEnded(detail);
  if (state is! EventDetailReady || games.isClosed) {
    controller.disarmTakeBack(game.id);
    return false;
  }

  final viewer = state.detail.attendance;
  final shown = games.state.games
      .where((each) => each.id == game.id)
      .firstOrNull;
  // Pressed as the viewer's own, it goes only while it is theirs: it never
  // asked.
  final attendeeId = own
      ? (offerGamesGate(state) != OfferGamesGate.hidden &&
                viewer != null &&
                viewer.id == shown?.attendeeId
            ? viewer.id
            : null)
      : (canTakeBackAnyGame(state) ? shown?.attendeeId : null);
  if (attendeeId == null) {
    controller.disarmTakeBack(game.id);
    games.add(
      EventGamesWriteDropped(
        EventGamesWrite.takeBack,
        title: game.title,
        subtitle: game.subtitle,
      ),
    );
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (games.state.busy) {
    controller.disarmTakeBack(game.id);
    return false;
  }
  games.add(
    EventGameTakenBack(
      state.detail.snapshot.event.id,
      attendeeId,
      game,
      attendeeIds: poolReadIds(state.detail),
    ),
  );
  return true;
}

/// One choice Nominate offers (#517): the scope it nominates for, and the
/// date it names, or null for the whole event.
typedef _NominateScope = ({NominationScope scope, EventOccurrence? date});

/// What Nominate offers on [detail] as of [now] (#517): the whole event,
/// then, on an event of more than one date, each date a game can still be
/// nominated for ([nominatableDates]), in their order. With one choice,
/// Nominate nominates for it; with more, it asks.
List<_NominateScope> _nominateScopes(
  EventDetail detail, {
  required DateTime now,
}) => [
  (scope: const WholeEventScope(), date: null),
  if (detail.snapshot.occurrences.length > 1)
    for (final date in nominatableDates(detail, now: now))
      (scope: DateScope(date.id), date: date),
];

/// Whether whoever brings [game] has answered Not going (#517), which the
/// server refuses a nomination for: the viewer, by their own answer on
/// [detail], as Offer games reads it; anyone else by their row on the
/// roster. Where the roster is withheld the pool holds only the viewer's own
/// games, so their answer decides.
bool _supplierNotGoing(EventDetail detail, OfferedGame game) {
  final viewer = detail.attendance;
  final supplier = viewer != null && viewer.id == game.attendeeId
      ? viewer
      : detail.snapshot.attendees
            ?.where((row) => row.id == game.attendeeId)
            .firstOrNull;
  return supplier?.status == EventParticipationStatus.notAttending;
}

/// Whether the nominations [state] holds say what a pool row supplies
/// (#517): there are some, or the last read to end, as [controller] draws
/// it, found none. None held otherwise says nothing: before a read has
/// ended, or once one is failed, hidden or gone. Nor do any while a
/// nominate's answer was lost and no read since has loaded
/// ([EventNominationsState.settling]): the server may have saved it, and it
/// takes the same row twice for one choice (backend#1214). Nominate waits
/// until then, as its press does when it comes to send ([_nominate]).
bool _nominationsKnown(
  EventNominationsState state,
  EventGamesTabController controller,
) =>
    !state.settling &&
    (state.nominations.isNotEmpty ||
        controller.drawnNominationsLoad(state) == EventNominationsLoad.loaded);

/// Why a pool row can't be nominated for any choice, from what [taken] says
/// of each, or null while one is left.
String? _alreadyTaken(
  EventsLocalizations l10n,
  List<NominateTaken> taken,
) {
  if (taken.isEmpty || taken.contains(NominateTaken.no)) return null;
  if (taken.every((each) => each == NominateTaken.nominated)) {
    return l10n.eventsNominateAlready;
  }
  if (taken.every((each) => each == NominateTaken.inLineup)) {
    return l10n.eventsNominateInLineup;
  }
  return l10n.eventsNominateAlreadyOrInLineup;
}

/// Nominates [game] (#517): for the whole event, or where there is more
/// than one choice ([_nominateScopes]), for the one chosen in
/// [showNominateScopeDialog], where a choice the row already supplies a
/// live nomination for, or its game is in the lineup for, can't be chosen.
/// The dialog, the nomination's outcome and a drop name the game as the row
/// does, with its subtitle ([gameName], #851). Completes true when the
/// nomination was sent, and false when nothing was: the dialog cancelled,
/// or as below.
///
/// It goes once any running detail read has ended ([readEnded]), for the
/// event as the detail shows it then, whose id a reconcile can have moved
/// (#499). Nothing is sent if, by then, the viewer isn't offered Nominate,
/// the game has left the pool, the choice is no longer offered, as a date
/// cancelled meanwhile isn't, or one that started meanwhile isn't, or the
/// row supplies a live nomination for it, or its game is in the lineup for
/// it: the page already shows that, and
/// the footer says the nomination was dropped, or a screen reader would hear
/// nothing happen. So [clock] is read as it is pressed and again then: the
/// server takes a nomination for a date that has started.
Future<bool> _nominate(
  BuildContext context,
  OfferedGame game, {
  required DateTime Function() clock,
}) async {
  // Read before anything is awaited: the dialog covers the row, and a
  // rebuild can take this context with it.
  final l10n = EventsLocalizations.of(context);
  final detail = context.read<EventDetailBloc>();
  final pool = context.read<EventGamesBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final controller = EventGamesTabScope.of(context);
  final shown = detail.state;
  if (shown is! EventDetailReady) return false;

  final now = clock();
  final choices = _nominateScopes(shown.detail, now: now);
  final NominationScope scope;
  if (choices.length == 1) {
    scope = choices.single.scope;
  } else {
    final chosen = await showNominateScopeDialog(
      context,
      title: gameName(l10n, game.title, game.subtitle),
      choices: [
        for (final choice in choices)
          (
            scope: choice.scope,
            label: switch (choice.date) {
              null => l10n.eventsNominationWholeEvent,
              final date => l10n.eventsNominationForDate(
                eventDateName(context, date, now: now),
              ),
            },
            taken: nominateTaken(
              game,
              nominations.state.nominations,
              scope: choice.scope,
            ),
          ),
      ],
    );
    if (chosen == null || nominations.isClosed) return false;
    scope = chosen;
  }

  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;
  final inPool = pool.state.games.any((shown) => shown.id == game.id);
  final offered = _nominateScopes(
    state.detail,
    now: clock(),
  ).any((each) => each.scope == scope);
  if (nominateGate(state) != NominateGate.open ||
      !_nominationsKnown(nominations.state, controller) ||
      !inPool ||
      !offered ||
      nominateTaken(game, nominations.state.nominations, scope: scope) !=
          NominateTaken.no) {
    nominations.add(
      NominationWriteDropped(
        NominationWrite.nominate,
        title: game.title,
        subtitle: game.subtitle,
      ),
    );
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  nominations.add(
    GameNominated(
      state.detail.snapshot.event.id,
      game,
      occurrenceId: switch (scope) {
        WholeEventScope() => null,
        DateScope(:final occurrenceId) => occurrenceId,
      },
    ),
  );
  return true;
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

/// One offered copy (#516): its picture, its name, the title with the
/// subtitle where it has one ([gameName], #851), where it is played, who
/// brings it and, where it supplies a live nomination, "Nominated" (#517),
/// as one node. Then its controls, each a node of its own: [nominate] where
/// the viewer is offered it, and [takeBack] where they may take it back.
/// Then [note], why Nominate can't be pressed, which its hint already says.
class _PoolRow extends StatelessWidget {
  const _PoolRow({
    required this.game,
    required this.who,
    required this.nominated,
    this.note,
    this.nominate,
    this.takeBack,
  });

  final OfferedGame game;

  /// Who brings it, as its third line says it.
  final String who;

  /// Whether it supplies a live nomination, which its marker says.
  final bool nominated;

  /// Drawn under the controls, and left out of the semantics tree.
  final String? note;

  final Widget? nominate;
  final Widget? takeBack;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final medium = switch (game.medium) {
      GameMedium.physical => l10n.eventsGamesMediumPhysical,
      GameMedium.digital => l10n.eventsGamesMediumDigital,
      null => null,
    };
    final nominate = this.nominate;
    final takeBack = this.takeBack;
    final note = this.note;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
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
                      Text(
                        gameName(l10n, game.title, game.subtitle),
                        style: theme.textTheme.bodyLarge,
                      ),
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
                      if (nominated) ...[
                        const BgeGap.xs(),
                        // Read as the node's last line, as its words alone:
                        // the chip's own node would add a selected state
                        // that a marker doesn't have. A chip's label can't
                        // wrap, so it scales down.
                        Semantics(
                          label: l10n.eventsPoolNominated,
                          child: ExcludeSemantics(
                            child: Chip(
                              key: EventDetailScreen.poolNominatedKey(game.id),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              avatar: const Icon(Icons.playlist_add_check),
                              label: GameFilterChipLabel(
                                l10n.eventsPoolNominated,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (nominate != null || takeBack != null)
                  Wrap(
                    spacing: tokens.spaceSm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [?nominate, ?takeBack],
                  ),
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
    );
  }
}

/// Nominate on a pool row (#517): a direct write, so disabled offline
/// through [BgeOnlineOnly], with the connection's reason as its hint. Named
/// for its game to a screen reader, as its row names it ([gameName], #851).
///
/// Online it is disabled, with the reason as its hint, while the nominations
/// couldn't be read or aren't shown to the viewer ([unread]), else while
/// whoever brings the game isn't going ([notGoing]), else while the row is
/// nominated already, or its game in the lineup, for everything Nominate
/// offers ([already]): a hint says
/// one thing, and those come in that order. It is disabled with no hint
/// while it may not be pressed for a while ([enabled]).
///
/// Its press can open the nominate dialog, which hands focus back to it as
/// it closes, just before the nomination goes out, and a disabled button
/// can't hold focus (#607). So, as Offer games is, it is held through
/// [HeldPress] from its press until its nomination is over ([runOver]):
/// enabled, ignoring presses and showing a spinner, wherever it would
/// otherwise be unavailable. A nomination of its own that leaves the row
/// nominated already for everything would disable it under the keyboard
/// user who pressed it, so then it stays inert, drawn as a disabled button
/// is and saying why, for as long as it holds focus, and is disabled once
/// focus moves on.
class _NominateButton extends StatefulWidget {
  const _NominateButton({
    required this.game,
    required this.unread,
    required this.notGoing,
    required this.already,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
  });

  final OfferedGame game;

  /// Why there are no nominations to go on, where waiting won't bring them:
  /// a first read that failed, or nominations not shown to the viewer. Null
  /// otherwise, a read still out included.
  final String? unread;

  /// Why it can't be pressed where whoever brings the game has answered Not
  /// going: the viewer, or someone else. Null where they haven't.
  final String? notGoing;

  /// Why the row can't be nominated for any choice Nominate offers, each
  /// taken already ([nominateTaken]). Null while one is left.
  final String? already;

  /// Whether it may be pressed now, connection and reasons aside: false
  /// while a detail read runs, the screen's own request is out, a
  /// nominations write is out, or the nominations haven't been read.
  final bool enabled;

  /// Whether no nominations write is out: once its own nomination went out,
  /// that is over.
  final bool runOver;

  /// Asks for the choice where there is one, and sends the nomination.
  /// Completes true when it was sent, and false when nothing was.
  final Future<bool> Function() onPressed;

  @override
  State<_NominateButton> createState() => _NominateButtonState();
}

class _NominateButtonState extends State<_NominateButton>
    with HeldPress<_NominateButton> {
  /// Whether its own nomination went out since it was last available, with
  /// focus not moved on from it since.
  bool _nominated = false;

  /// Whether it holds focus.
  bool _focused = false;

  @override
  bool get heldActionOver => widget.runOver;

  Future<bool> _press() async {
    final sent = await widget.onPressed();
    if (sent) _nominated = true;
    return sent;
  }

  void _focusChanged(bool focused) {
    if (!mounted) return;
    setState(() {
      _focused = focused;
      if (!focused) _nominated = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final unread = widget.unread;
    final notGoing = widget.notGoing;
    final already = widget.already;
    final available =
        widget.enabled &&
        !offline &&
        unread == null &&
        notGoing == null &&
        already == null;
    if (available) _nominated = false;
    // Offline, with no nominations to go on, or not going, it is disabled,
    // pressed or not: no press made it so (#49).
    final held = heldInert(
      available: available,
      disabled: offline || unread != null || notGoing != null,
    );
    // Nominated already by its own press, which is all that keeps it from
    // being pressed, and holding focus: inert, not disabled, or focus would
    // go (#607).
    final kept =
        !held &&
        _nominated &&
        _focused &&
        already != null &&
        widget.enabled &&
        !offline &&
        unread == null &&
        notGoing == null;
    final inert = held || kept;
    // One reason: offline [BgeOnlineOnly] gives its own.
    final reason = offline ? null : unread ?? notGoing ?? already;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: _focusChanged,
      child: BgeOnlineOnly(
        showNote: false,
        child: Semantics(
          hint: reason,
          child: BgeInertButton(
            inert: inert,
            label: l10n.eventsNominateNamed(
              gameName(l10n, widget.game.title, widget.game.subtitle),
            ),
            onPressed: available || inert
                ? () => unawaited(holdPress(_press))
                : null,
            builder: (context, focusNode, onPressed) => TextButton.icon(
              key: EventDetailScreen.poolNominateKey(widget.game.id),
              focusNode: focusNode,
              onPressed: onPressed,
              style: kept ? _unavailableStyle(context) : null,
              icon: held
                  ? const _HeldSpinner()
                  : const Icon(Icons.playlist_add),
              label: Text(l10n.eventsNominate),
            ),
          ),
        ),
      ),
    );
  }

  /// Drawn as a disabled button is, and with no answer to a press or a
  /// hover. The focus overlay stays, since it is how a keyboard user sees
  /// where they are.
  ButtonStyle _unavailableStyle(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(color),
      iconColor: WidgetStatePropertyAll(color),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? null
            : color.withValues(alpha: 0),
      ),
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.basic),
      splashFactory: NoSplash.splashFactory,
      enableFeedback: false,
    );
  }
}

/// Take back on one of the viewer's rows (#516), or, for whoever may take
/// back anyone's game, on someone else's (#518): a direct write, so
/// disabled offline through [BgeOnlineOnly], saying why as its hint.
/// Disabled while another write is out or a detail read runs ([enabled]).
/// Named for its game to a screen reader, as its row names it ([gameName],
/// #851).
///
/// It keeps focus through its own take-back (#607). On someone else's row
/// its press opens a dialog first, which hands focus back to it as it
/// closes, just before the take-back goes out, and a disabled button can't
/// hold focus. So, as Withdraw is, it is held through [HeldPress] from its
/// press until its take-back is over ([runOver]): enabled, ignoring presses
/// and showing a spinner, wherever it would otherwise be unavailable. It is
/// inert, too, while its row's take-back is out ([inert]), however that
/// began.
class _TakeBackButton extends StatefulWidget {
  const _TakeBackButton({
    required this.game,
    required this.area,
    required this.inert,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
  });

  final OfferedGame game;

  /// Holds the button, so a row that leaves can say it held focus.
  final FocusNode area;

  /// Whether this row's take-back is out.
  final bool inert;

  /// Whether it may be pressed now, connection aside.
  final bool enabled;

  /// Whether none of the pool's writes is out: once its own take-back went
  /// out, that is over.
  final bool runOver;

  /// Asks first where it asks, and sends the take-back. Completes true when
  /// it was sent, and false when nothing was.
  final Future<bool> Function() onPressed;

  @override
  State<_TakeBackButton> createState() => _TakeBackButtonState();
}

class _TakeBackButtonState extends State<_TakeBackButton>
    with HeldPress<_TakeBackButton> {
  @override
  bool get heldActionOver => widget.runOver;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final game = widget.game;
    final available = widget.enabled && !offline;
    // Offline it is disabled, pressed or not: no press made it so (#49).
    final inert =
        heldInert(available: available, disabled: offline) ||
        (widget.inert && !offline);

    return Focus(
      focusNode: widget.area,
      includeSemantics: false,
      child: BgeOnlineOnly(
        showNote: false,
        child: BgeInertButton(
          inert: inert,
          label: l10n.eventsGamesTakeBackNamed(
            gameName(l10n, game.title, game.subtitle),
          ),
          onPressed: available || inert
              ? () => unawaited(holdPress(widget.onPressed))
              : null,
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

/// A held button's icon while its write is out, Take back's, Offer games'
/// or Nominate's: scaled with the label beside it, in the button's icon
/// colour, as the screen's other held buttons'.
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
