import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_lineup_bloc.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_game_offers.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_lineup.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/detail/games_date_view.dart';
import 'package:events/src/detail/nominate_scopes.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/confirm_dialog.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/held_spinner.dart';
import 'package:events/src/widgets/lineup_row_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';

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
Future<bool> takeBackGame(
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

/// What Nominate is in [view], the date view in use (#1042), on [detail] as
/// of [now]: the choices it nominates for ([nominateScopes]), each where
/// the viewer is offered Nominate under its own scope's mode
/// ([nominateGate], [scopeMode], #519, #1070), or null where none is.
///
/// Under a view there is one scope, the view's, so the view's mode decides
/// ([viewMode]): null where it offers no Nominate, or while it is unknown,
/// its date's rules still to come from a read (#1063); otherwise the view's
/// choice, none where its date can no longer be nominated for, which leaves
/// Nominate offered but with nothing to nominate. With no view the one
/// choice is the whole event (#1062), checked against the event's mode.
/// The check per choice is the add's ([openChoicesIn]). One rule for the
/// pool's rows, their quick looks, a press's re-check ([nominateGame]) and
/// the Nominations sub-tab's pointer to the Pool.
List<NominateScope>? nominateChoicesIn(
  EventDetailReady detail, {
  required GamesDateView? view,
  required DateTime now,
}) => openChoicesIn(
  detail,
  view: view,
  scopes: nominateScopes(detail.detail, now: now, view: view),
  open: (mode) => nominateGate(detail, mode: mode) == NominateGate.open,
);

/// Whether the nominations [state] holds say what a pool row supplies
/// (#517): there are some, or the last read to end, as [controller] draws
/// it, found none. None held otherwise says nothing: before a read has
/// ended, or once one is failed, hidden or gone. Nor do any while a
/// nominate's answer was lost and no read since has loaded
/// ([EventNominationsState.settling]): the server may have saved it, and it
/// takes the same row twice for one choice (backend#1214). Nominate waits
/// until then, as its press does when it comes to send ([nominateGame]).
bool nominationsKnown(
  EventNominationsState state,
  EventGamesTabController controller,
) =>
    !state.settling &&
    (state.nominations.isNotEmpty ||
        controller.drawnNominationsLoad(state) == EventNominationsLoad.loaded);

/// Why a pool row can't be nominated for any choice, from what [taken] says
/// of each, or null while one is left.
String? alreadyTaken(
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

/// What Nominate on a pool row is built with (#517): [NominateButton]'s
/// [NominateButton.closed], [NominateButton.unread],
/// [NominateButton.notGoing], [NominateButton.already],
/// [NominateButton.enabled] and [NominateButton.runOver].
typedef NominateGates = ({
  String? closed,
  String? unread,
  String? notGoing,
  String? already,
  bool enabled,
  bool runOver,
});

/// Why Nominate on a pool row can't be pressed, where anything says so, in
/// the one order its hint says it and its row and its quick look draw it
/// (STYLE_GUIDE §4): the date view's date takes no nomination now
/// ([closed], #1042), else the nominations aren't known ([unread]), else
/// whoever brings the game isn't going ([notGoing]), else it is nominated
/// already, or in the lineup, for every choice ([already]). Null where none
/// holds.
String? nominateReason({
  required String? closed,
  required String? unread,
  required String? notGoing,
  required String? already,
}) => closed ?? unread ?? notGoing ?? already;

/// Nominate's one reason, from its gates ([nominateReason]).
extension NominateGatesReason on NominateGates {
  /// What its hint says.
  String? get reason => nominateReason(
    closed: closed,
    unread: unread,
    notGoing: notGoing,
    already: already,
  );

  /// What the row and the quick look draw under Nominate: [reason], but for
  /// nominated already or in the lineup, which the button's own label,
  /// Nominated, draws (#947).
  String? get drawnReason {
    final reason = this.reason;
    return reason == already ? null : reason;
  }
}

/// What Take back on a pool row is built with (#516): [TakeBackButton]'s
/// [TakeBackButton.blockedReason] (#905), [TakeBackButton.inert],
/// [TakeBackButton.enabled] and [TakeBackButton.runOver].
typedef TakeBackGates = ({
  String? blockedReason,
  bool inert,
  bool enabled,
  bool runOver,
});

/// What a pool row says of its copy and builds its controls with (#957):
/// who brings it, as its status line says it; whether that line says
/// Nominated (#947, #946); and Nominate's, Add to lineup's (#519) and Take
/// back's arguments where each is offered, null where it isn't. The row
/// builds one of them (#946), its quick look each.
typedef PoolRowGates = ({
  String who,
  bool nominatedLine,
  NominateGates? nominate,
  AddToLineupGates? addToLineup,
  TakeBackGates? takeBack,
});

/// What the row of [game] says and builds (#957), from the detail, the
/// pool's, the nominations' and the lineup's states, the tab's
/// [controller], the roster's [names], whether the screen is [acting]
/// (`eventScreenActing`), and Nominate's [scopes] and Add to lineup's
/// [addScopes] as of the clock in the date view ([nominateChoicesIn],
/// [lineupAddChoicesIn], #1042), the same for every row, so a list makes
/// them once, by the clock's [now]: one place, so the row and its quick
/// look build the same controls under the same rules.
///
/// Nominate, where the viewer is offered it under the mode of the date view
/// ([scopes] not null, #519), on an event with a nominations' state.
/// Disabled, saying why, where the date view's date can no longer be
/// nominated for, started or cancelled, so [scopes] is empty (#1042); where
/// the nominations couldn't be read or aren't shown to the viewer, where a
/// nominate's lost answer couldn't be checked, where whoever brings the game
/// isn't going, or where the row is nominated already, or its game in the
/// lineup, for every choice: one reason, in that order ([nominateReason]).
/// And with nothing to say while a detail read runs, the screen is acting, a
/// nominations write is out, or the nominations aren't known
/// ([nominationsKnown]). Its game is in the lineup by [lineup] where that is
/// known ([knownLineup], #519), else by the nominations.
///
/// Add to lineup on every row, anyone's copy, where the viewer is offered a
/// direct add under the mode of the date view ([addScopes] not null, #519),
/// on an event with a lineup's state. The row's main action under a
/// host-only view, in Nominate's place, and otherwise its quick look's alone
/// ([AddToLineupGates]' `onRow`). Disabled, saying why, where the date view's
/// date takes no add, so [addScopes] is empty: called off, or in a status
/// this client can't read ([lineupAddClosedReason]); and where whoever
/// brings the game isn't going: one reason, in that order
/// ([lineupAddReason]). And with nothing to say while a detail read runs,
/// the screen is acting, or a lineup write is out.
///
/// Take back on the viewer's own row where they may offer games or take
/// them back ([offerGamesGate]), and on anyone else's where they may take
/// back anyone's game ([canTakeBackAnyGame], #518). Disabled, saying why,
/// where any read says the row still supplies a live nomination or a
/// lineup game still ahead ([takeBackSupplies], #905), in the words a
/// take-back's 409 would say ([stillSuppliesMessage]): where none can tell,
/// it stays enabled, and the 409 answers. And with nothing to say, as the
/// roster's controls are (#589), while a detail read runs, the screen is
/// acting, or another of the pool's writes is out.
PoolRowGates poolRowGates(
  EventsLocalizations l10n, {
  required OfferedGame game,
  required EventDetailReady detail,
  required EventGamesState games,
  required EventNominationsState? nominations,
  required EventGamesTabController controller,
  required Map<String, String?> names,
  required bool acting,
  required List<NominateScope>? scopes,
  required List<NominateScope>? addScopes,
  required DateTime now,
  EventLineupState? lineup,
}) {
  final viewerId = detail.detail.attendance?.id;
  final lineupGames = knownLineup(lineup);
  final own = viewerId != null && game.attendeeId == viewerId;
  final nominated = nominations?.nominations ?? const <EventNomination>[];
  // Nominate's choices where it is built: offered, on an event with a
  // nominations' state.
  final choices = nominations == null ? null : scopes;
  final already = choices == null
      ? null
      : alreadyTaken(l10n, [
          for (final each in choices)
            nominateTaken(
              game,
              nominated,
              scope: each.scope,
              lineup: lineupGames,
            ),
        ]);
  final takesBack = own
      ? offerGamesGate(detail) != OfferGamesGate.hidden
      : canTakeBackAnyGame(detail);
  // What keeps it from being taken back, where a read can tell (#905), in
  // the 409's words, which name whose games it is off where it isn't the
  // viewer's own (#518).
  String? blockedReason() => stillSuppliesMessage(
    l10n,
    title: gameName(l10n, game.title, game.subtitle),
    supplies: takeBackSupplies(
      detail.detail,
      game,
      nominations: nominations?.nominations,
      lineup: lineupGames,
      now: now,
    ),
    by: stillSuppliedBy(game.id, nominated, viewerId: viewerId),
    offeredBy: own
        ? null
        : names[game.attendeeId] ?? l10n.eventsAttendeeSomeone,
  );
  // In the second person on the viewer's own rows, as the row's line is.
  final notGoing = !supplierNotGoing(detail.detail, game)
      ? null
      : own
      ? l10n.eventsNominateYouNotGoingHint
      : l10n.eventsNominateSupplierNotGoingHint;

  return (
    who: own
        ? l10n.eventsGamesYours
        : l10n.eventsGamesTheirs(
            names[game.attendeeId] ?? l10n.eventsAttendeeSomeoneStart,
          ),
    // Nominate says it where it can't be pressed for any choice; otherwise
    // the row's status line does (#947). Only the nominations the date view
    // shows count, not those for another date (#1090); Take back's block
    // still counts every one (#905).
    nominatedLine:
        suppliesLive(
          game,
          nominationsInView(controller.dateView, nominated),
        ) &&
        (choices == null || already == null),
    nominate: nominations == null || choices == null
        ? null
        : (
            // A date view whose date takes no nomination now (#1042).
            closed: choices.isEmpty ? l10n.eventsNominateDateClosed : null,
            unread: _nominateUnread(l10n, nominations, controller),
            notGoing: notGoing,
            already: already,
            // As the tab's other writes are, and not while another
            // nominations write is out. Nor before the nominations are
            // known: none held before a read has answered says nothing of
            // what a row supplies, and nothing stops a second nomination of
            // a row for one choice (backend#1214).
            enabled:
                !detail.reading &&
                !acting &&
                !nominations.busy &&
                nominationsKnown(nominations, controller),
            runOver: !nominations.busy,
          ),
    addToLineup: lineup == null || addScopes == null
        ? null
        : (
            // A date view whose date takes no add (#1042): called off, or in
            // a status this client can't read. One that has started still
            // takes a game (#519).
            closed: addScopes.isEmpty
                ? lineupAddClosedReason(
                    l10n,
                    detail.detail,
                    controller.dateView,
                  )
                : null,
            notGoing: notGoing,
            // As the tab's other writes are, and not while another lineup
            // write is out.
            enabled: !detail.reading && !acting && !lineup.busy,
            runOver: !lineup.busy,
            // Under a host-only view, where nothing can be nominated, it is
            // the row's main action, in Nominate's place (#519). Never under
            // an unknown mode (#1063), where it isn't built at all.
            onRow:
                viewMode(detail, controller.dateView) ==
                GameAdditionMode.hostOnly,
          ),
    takeBack: !takesBack
        ? null
        : (
            blockedReason: blockedReason(),
            inert: games.takingBack == game.id,
            // As the roster's controls are (#589): not while a detail read
            // runs, the screen is acting, nor while another of the pool's
            // writes is out.
            enabled: !detail.reading && !acting && !games.busy,
            runOver: !games.busy,
          ),
  );
}

/// Nominate, Add to lineup (#519) and Take back on [game], for its row and
/// its quick look (#957), each built from its gates in [gates]
/// ([poolRowGates]) where it is offered, and null where it isn't. Nominate
/// nominates by [clock] ([nominateGame]), and Add to lineup adds by it
/// ([addToLineup]). Take back's press, however it came, arms [controller]'s
/// hand-off, then takes the game back ([takeBackGame]), naming whoever
/// offered it from [names], by the viewer's roster row [viewerId]. Each
/// button carries the row's key unless [nominateKey], [addToLineupKey] or
/// [takeBackKey] gives it another.
({
  NominateButton? nominate,
  AddToLineupButton? addToLineup,
  TakeBackButton? takeBack,
})
poolRowButtons(
  BuildContext context, {
  required OfferedGame game,
  required PoolRowGates gates,
  required EventGamesTabController controller,
  required String? viewerId,
  required Map<String, String?> names,
  required DateTime Function() clock,
  Key? nominateKey,
  Key? addToLineupKey,
  Key? takeBackKey,
}) {
  final nominate = gates.nominate;
  final add = gates.addToLineup;
  final takeBack = gates.takeBack;
  return (
    nominate: nominate == null
        ? null
        : NominateButton(
            buttonKey: nominateKey,
            game: game,
            closed: nominate.closed,
            unread: nominate.unread,
            notGoing: nominate.notGoing,
            already: nominate.already,
            enabled: nominate.enabled,
            runOver: nominate.runOver,
            onPressed: () => nominateGame(context, game, clock: clock),
          ),
    addToLineup: add == null
        ? null
        : AddToLineupButton(
            buttonKey: addToLineupKey,
            game: game,
            closed: add.closed,
            notGoing: add.notGoing,
            enabled: add.enabled,
            runOver: add.runOver,
            onPressed: () => addToLineup(context, game, clock: clock),
          ),
    takeBack: takeBack == null
        ? null
        : TakeBackButton(
            buttonKey: takeBackKey,
            game: game,
            blockedReason: takeBack.blockedReason,
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
  );
}

/// Why Nominate waits with no nominations to go on, where the wait won't
/// end by itself (#517): a first read that failed, nominations this viewer
/// isn't shown, or a nominate's lost answer whose read failed. A read that
/// is still out says nothing.
String? _nominateUnread(
  EventsLocalizations l10n,
  EventNominationsState nominations,
  EventGamesTabController controller,
) {
  final drawn = controller.drawnNominationsLoad(nominations);
  if (nominations.settling) {
    return switch (drawn) {
      EventNominationsLoad.failed => l10n.eventsNominateUnsettled,
      EventNominationsLoad.hidden => l10n.eventsNominationsHiddenTitle,
      _ => null,
    };
  }
  if (nominations.nominations.isNotEmpty) return null;
  return switch (drawn) {
    EventNominationsLoad.failed => l10n.eventsNominationsFailedTitle,
    EventNominationsLoad.hidden => l10n.eventsNominationsHiddenTitle,
    _ => null,
  };
}

/// Nominates [game] (#517): for the one choice the date view in use as it
/// is pressed offers ([nominateScopes], #1042), its date or the whole event.
/// The nomination's outcome and a drop name the game as the row does, with
/// its subtitle ([gameName], #851). Completes true when the nomination was
/// sent, and false when nothing was, as below.
///
/// It goes once any running detail read has ended ([readEnded]), for the
/// event as the detail shows it then, whose id a reconcile can have moved
/// (#499). Nothing is sent if, by then, the viewer isn't offered Nominate
/// for the choice under its own scope's mode, as the read left it
/// ([nominateChoicesIn], #519, #1070), the game has left the pool,
/// the choice is no longer offered, as a date cancelled meanwhile isn't, or
/// one that started meanwhile isn't, or the row supplies a live nomination
/// for it, or its game is in the lineup for it: the page already shows
/// that, and the footer says the nomination was dropped, or a screen reader
/// would hear nothing happen. So too where the view offers no choice as it
/// is pressed, its date having started since the row was built. So [clock]
/// is read as it is pressed and again then: the server takes a nomination
/// for a date that has started. The view is the one it was pressed under,
/// whatever is chosen meanwhile.
Future<bool> nominateGame(
  BuildContext context,
  OfferedGame game, {
  required DateTime Function() clock,
}) async {
  // Read before anything is awaited: a rebuild can take this context with
  // it.
  final detail = context.read<EventDetailBloc>();
  final pool = context.read<EventGamesBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final lineup = context.read<EventLineupBloc>();
  final controller = EventGamesTabScope.of(context);
  final view = controller.dateView;
  final shown = detail.state;
  if (shown is! EventDetailReady) return false;

  void dropped() => nominations.add(
    NominationWriteDropped(
      NominationWrite.nominate,
      title: game.title,
      subtitle: game.subtitle,
    ),
  );

  final now = clock();
  final choices = nominateScopes(shown.detail, now: now, view: view);
  if (choices.isEmpty) {
    dropped();
    return false;
  }
  final scope = choices.single.scope;

  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;
  final inPool = pool.state.games.any((shown) => shown.id == game.id);
  // Offered still, for the choice made, under its own scope's mode.
  final offered =
      nominateChoicesIn(
        state,
        view: view,
        now: clock(),
      )?.any((each) => each.scope == scope) ??
      false;
  if (!nominationsKnown(nominations.state, controller) ||
      !inPool ||
      !offered ||
      nominateTaken(
            game,
            nominations.state.nominations,
            scope: scope,
            // As the lineup stands now, not as the row was built.
            lineup: knownLineup(lineup.state),
          ) !=
          NominateTaken.no) {
    dropped();
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  nominations.add(
    GameNominated(
      state.detail.snapshot.event.id,
      game,
      occurrenceId: scope.occurrenceId,
    ),
  );
  return true;
}

/// Nominate on a pool row (#517): a direct write, so disabled offline
/// through [BgeOnlineOnly], with the connection's reason as its hint. Named
/// for its game to a screen reader, as its row names it ([gameName], #851).
///
/// Where the row is nominated already, or its game in the lineup, for
/// everything it offers ([already]), it reads Nominated with a check and is
/// named "Nominated: " the game, so the row has one control, not a marker
/// and a button that say the same thing (#947).
///
/// Online it is disabled, with the reason as its hint, while the date view's
/// date can no longer be nominated for ([closed], #1042), else while the
/// nominations couldn't be read or aren't shown to the viewer ([unread]),
/// else while whoever brings the game isn't going ([notGoing]), else while
/// the row is nominated already, or its game in the lineup, for everything
/// Nominate offers ([already]): a hint says one thing, and those come in
/// that order. It is disabled with no hint while it may not be pressed for
/// a while ([enabled]).
///
/// Its press waits for any running detail read to end before the
/// nomination goes out, and a disabled button can't hold focus (#607). So,
/// as Offer games is, it is held through [HeldPress] from its press until
/// its nomination is over ([runOver]): enabled, ignoring presses and
/// showing a spinner, wherever it would otherwise be unavailable. A
/// nomination of its own that leaves the row nominated already for
/// everything would disable it under the keyboard user who pressed it, so
/// then it stays inert, drawn as a disabled button is and saying why, for as
/// long as it holds focus, and is disabled once focus moves on.
class NominateButton extends StatefulWidget {
  const NominateButton({
    required this.game,
    required this.closed,
    required this.unread,
    required this.notGoing,
    required this.already,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
    this.buttonKey,
    super.key,
  });

  final OfferedGame game;

  /// Key on the button itself: the row's ([EventDetailScreen.poolNominateKey])
  /// where null, or the quick look's (#957).
  final Key? buttonKey;

  /// Why it can't be pressed in the date view in use, where its date can no
  /// longer be nominated for: it has started, or it was cancelled (#1042).
  /// Null otherwise.
  final String? closed;

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
  State<NominateButton> createState() => NominateButtonState();
}

class NominateButtonState extends State<NominateButton>
    with HeldPress<NominateButton> {
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
    final closed = widget.closed;
    final unread = widget.unread;
    final notGoing = widget.notGoing;
    final already = widget.already;
    final available =
        widget.enabled &&
        !offline &&
        closed == null &&
        unread == null &&
        notGoing == null &&
        already == null;
    if (available) _nominated = false;
    // Offline, with its date closed, with no nominations to go on, or not
    // going, it is disabled, pressed or not: no press made it so (#49).
    final held = heldInert(
      available: available,
      disabled: offline || closed != null || unread != null || notGoing != null,
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
        closed == null &&
        unread == null &&
        notGoing == null;
    final inert = held || kept;
    // One reason: offline [BgeOnlineOnly] gives its own.
    final reason = offline
        ? null
        : nominateReason(
            closed: closed,
            unread: unread,
            notGoing: notGoing,
            already: already,
          );

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
            label: already == null
                ? l10n.eventsNominateNamed(
                    gameName(l10n, widget.game.title, widget.game.subtitle),
                  )
                : l10n.eventsNominatedNamed(
                    gameName(l10n, widget.game.title, widget.game.subtitle),
                  ),
            onPressed: available || inert
                ? () => unawaited(holdPress(_press))
                : null,
            builder: (context, focusNode, onPressed) => TextButton.icon(
              key:
                  widget.buttonKey ??
                  EventDetailScreen.poolNominateKey(widget.game.id),
              focusNode: focusNode,
              onPressed: onPressed,
              style: kept ? _unavailableStyle(context) : null,
              icon: held
                  ? const HeldSpinner()
                  : Icon(already == null ? Icons.playlist_add : Icons.check),
              label: Text(
                already == null
                    ? l10n.eventsNominate
                    : l10n.eventsPoolNominated,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Drawn as a disabled button is, and with no answer to a press or a hover:
/// for a pool row's button kept inert while it holds focus, though it can't
/// be pressed (#607). The focus overlay stays, since it is how a keyboard
/// user sees where they are.
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

/// Take back on one of the viewer's rows (#516), or, for whoever may take
/// back anyone's game, on someone else's (#518): a direct write, so
/// disabled offline through [BgeOnlineOnly], saying why as its hint.
/// Named for its game to a screen reader, as its row names it ([gameName],
/// #851).
///
/// Online it is disabled, with the reason as its hint, where a read says
/// the row still supplies a live nomination or a lineup game still ahead
/// ([blockedReason], #905): STYLE_GUIDE §5, disable, don't hide. Its row,
/// or its quick look, draws the same words under it. It is disabled with no
/// hint while another write is out or a detail read runs ([enabled]).
///
/// It keeps focus through its own take-back (#607). On someone else's row
/// its press opens a dialog first, which hands focus back to it as it
/// closes, just before the take-back goes out, and a disabled button can't
/// hold focus. So, as Withdraw is, it is held through [HeldPress] from its
/// press until its take-back is over ([runOver]): enabled, ignoring presses
/// and showing a spinner, wherever it would otherwise be unavailable. It is
/// inert, too, while its row's take-back is out ([inert]), however that
/// began. A take-back of its own that the server refuses is followed by a
/// read of the pool, which can say why, and would then disable it under the
/// keyboard user who pressed it. So once its own take-back went out, a
/// reason keeps it inert, drawn as a disabled button is and saying why, for
/// as long as it holds focus, as Nominate is kept, and it is disabled once
/// focus moves on.
class TakeBackButton extends StatefulWidget {
  const TakeBackButton({
    required this.game,
    required this.blockedReason,
    required this.inert,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
    this.buttonKey,
    super.key,
  });

  final OfferedGame game;

  /// Key on the button itself: the row's ([EventDetailScreen.poolTakeBackKey])
  /// where null, or the quick look's (#957).
  final Key? buttonKey;

  /// Why it can't be pressed, where a read says the row still supplies a
  /// live nomination or a lineup game still ahead: the step that frees it,
  /// in a take-back's 409's words ([stillSuppliesMessage], #905). Null where
  /// none says so, or none can tell, when the 409 is still the answer.
  final String? blockedReason;

  /// Whether this row's take-back is out.
  final bool inert;

  /// Whether it may be pressed now, connection and [blockedReason] aside.
  final bool enabled;

  /// Whether none of the pool's writes is out: once its own take-back went
  /// out, that is over.
  final bool runOver;

  /// Asks first where it asks, and sends the take-back. Completes true when
  /// it was sent, and false when nothing was.
  final Future<bool> Function() onPressed;

  @override
  State<TakeBackButton> createState() => TakeBackButtonState();
}

class TakeBackButtonState extends State<TakeBackButton>
    with HeldPress<TakeBackButton> {
  /// Whether its own take-back went out, with focus not moved on from it
  /// since.
  bool _tookBack = false;

  /// Whether it holds focus.
  bool _focused = false;

  @override
  bool get heldActionOver => widget.runOver;

  Future<bool> _press() async {
    final sent = await widget.onPressed();
    if (sent) _tookBack = true;
    return sent;
  }

  void _focusChanged(bool focused) {
    if (!mounted) return;
    setState(() {
      _focused = focused;
      if (!focused) _tookBack = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final game = widget.game;
    final blocked = widget.blockedReason;
    final available = widget.enabled && !offline && blocked == null;
    // Offline it is disabled, pressed or not: no press made it so (#49).
    final held =
        heldInert(available: available, disabled: offline) ||
        (widget.inert && !offline);
    // Its own take-back gone out, a reason since, which is all that keeps
    // it from being pressed, and holding focus: inert, not disabled, or
    // focus would go (#607).
    final kept =
        !held &&
        _tookBack &&
        _focused &&
        blocked != null &&
        widget.enabled &&
        !offline;
    final inert = held || kept;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: _focusChanged,
      child: BgeOnlineOnly(
        showNote: false,
        child: Semantics(
          // One reason: offline [BgeOnlineOnly] gives its own.
          hint: offline ? null : blocked,
          child: BgeInertButton(
            inert: inert,
            label: l10n.eventsGamesTakeBackNamed(
              gameName(l10n, game.title, game.subtitle),
            ),
            onPressed: available || inert
                ? () => unawaited(holdPress(_press))
                : null,
            builder: (context, focusNode, onPressed) => TextButton.icon(
              key:
                  widget.buttonKey ??
                  EventDetailScreen.poolTakeBackKey(game.id),
              focusNode: focusNode,
              onPressed: onPressed,
              style: kept ? _unavailableStyle(context) : null,
              icon: held
                  ? const HeldSpinner()
                  : const Icon(Icons.remove_circle_outline),
              label: Text(l10n.eventsGamesTakeBack),
            ),
          ),
        ),
      ),
    );
  }
}
