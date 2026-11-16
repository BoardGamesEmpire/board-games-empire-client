import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
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
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/held_spinner.dart';
import 'package:events/src/widgets/nominate_scope_dialog.dart';
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

/// One choice Nominate offers (#517): the scope it nominates for, and the
/// date it names, or null for the whole event.
typedef NominateScope = ({NominationScope scope, EventOccurrence? date});

/// What Nominate offers on [detail] as of [now] (#517): the whole event,
/// then, on an event of more than one date, each date a game can still be
/// nominated for ([nominatableDates]), in their order. With one choice,
/// Nominate nominates for it; with more, it asks.
List<NominateScope> nominateScopes(
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
bool supplierNotGoing(EventDetail detail, OfferedGame game) {
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
/// [NominateButton.unread], [NominateButton.notGoing],
/// [NominateButton.already], [NominateButton.enabled] and
/// [NominateButton.runOver].
typedef NominateGates = ({
  String? unread,
  String? notGoing,
  String? already,
  bool enabled,
  bool runOver,
});

/// What Take back on a pool row is built with (#516): [TakeBackButton]'s
/// [TakeBackButton.inert], [TakeBackButton.enabled] and
/// [TakeBackButton.runOver].
typedef TakeBackGates = ({bool inert, bool enabled, bool runOver});

/// What a pool row says of its copy and builds its controls with (#957):
/// who brings it, as its status line says it; whether that line says
/// Nominated (#947, #946); and Nominate's and Take back's arguments where
/// each is offered, null where it isn't. The row builds one of the two
/// (#946), its quick look both.
typedef PoolRowGates = ({
  String who,
  bool nominatedLine,
  NominateGates? nominate,
  TakeBackGates? takeBack,
});

/// What the row of [game] says and builds (#957), from the detail, the
/// pool's and the nominations' states, the tab's [controller], the
/// roster's [names], whether the screen is [acting]
/// (`eventScreenActing`), and Nominate's [scopes] as of the clock
/// ([nominateScopes]), the same for every row, so a list makes them once:
/// one place, so the row and its quick look build the same controls under
/// the same rules.
///
/// Nominate, where the viewer is offered it ([nominateGate]), on an event
/// with a nominations' state. Disabled, saying why, where the nominations
/// couldn't be read or aren't shown to the viewer, where a nominate's lost
/// answer couldn't be checked, where whoever brings the game isn't going, or
/// where the row is nominated already, or its game in the lineup, for every
/// choice; and with nothing to say while a detail read runs, the screen is
/// acting, a nominations write is out, or the nominations aren't known
/// ([nominationsKnown]).
///
/// Take back on the viewer's own row where they may offer games or take
/// them back ([offerGamesGate]), and on anyone else's where they may take
/// back anyone's game ([canTakeBackAnyGame], #518). Disabled, as the
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
  required List<NominateScope> scopes,
}) {
  final viewerId = detail.detail.attendance?.id;
  final own = viewerId != null && game.attendeeId == viewerId;
  final nominated = nominations?.nominations ?? const <EventNomination>[];
  final nominating =
      nominations != null && nominateGate(detail) == NominateGate.open;
  final already = nominating
      ? alreadyTaken(l10n, [
          for (final each in scopes)
            nominateTaken(game, nominated, scope: each.scope),
        ])
      : null;
  final takesBack = own
      ? offerGamesGate(detail) != OfferGamesGate.hidden
      : canTakeBackAnyGame(detail);

  return (
    who: own
        ? l10n.eventsGamesYours
        : l10n.eventsGamesTheirs(
            names[game.attendeeId] ?? l10n.eventsAttendeeSomeoneStart,
          ),
    // Nominate says it where it can't be pressed for any choice; otherwise
    // the row's status line does (#947).
    nominatedLine:
        suppliesLive(game, nominated) && (!nominating || already == null),
    nominate: nominations == null || !nominating
        ? null
        : (
            unread: _nominateUnread(l10n, nominations, controller),
            // In the second person on the viewer's own rows, as the row's
            // line is.
            notGoing: !supplierNotGoing(detail.detail, game)
                ? null
                : own
                ? l10n.eventsNominateYouNotGoingHint
                : l10n.eventsNominateSupplierNotGoingHint,
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
    takeBack: !takesBack
        ? null
        : (
            inert: games.takingBack == game.id,
            // As the roster's controls are (#589): not while a detail read
            // runs, the screen is acting, nor while another of the pool's
            // writes is out.
            enabled: !detail.reading && !acting && !games.busy,
            runOver: !games.busy,
          ),
  );
}

/// Nominate and Take back on [game], for its row and its quick look (#957),
/// each built from its gates in [gates] ([poolRowGates]) where it is
/// offered, and null where it isn't. Nominate nominates by [clock]
/// ([nominateGame]). Take back's press, however it came, arms [controller]'s
/// hand-off, then takes the game back ([takeBackGame]), naming whoever
/// offered it from [names], by the viewer's roster row [viewerId]. Each
/// button carries the row's key unless [nominateKey] or [takeBackKey] gives
/// it another.
({NominateButton? nominate, TakeBackButton? takeBack}) poolRowButtons(
  BuildContext context, {
  required OfferedGame game,
  required PoolRowGates gates,
  required EventGamesTabController controller,
  required String? viewerId,
  required Map<String, String?> names,
  required DateTime Function() clock,
  Key? nominateKey,
  Key? takeBackKey,
}) {
  final nominate = gates.nominate;
  final takeBack = gates.takeBack;
  return (
    nominate: nominate == null
        ? null
        : NominateButton(
            buttonKey: nominateKey,
            game: game,
            unread: nominate.unread,
            notGoing: nominate.notGoing,
            already: nominate.already,
            enabled: nominate.enabled,
            runOver: nominate.runOver,
            onPressed: () => nominateGame(context, game, clock: clock),
          ),
    takeBack: takeBack == null
        ? null
        : TakeBackButton(
            buttonKey: takeBackKey,
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

/// Nominates [game] (#517): for the whole event, or where there is more
/// than one choice ([nominateScopes]), for the one chosen in
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
Future<bool> nominateGame(
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
  final choices = nominateScopes(shown.detail, now: now);
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
  final offered = nominateScopes(
    state.detail,
    now: clock(),
  ).any((each) => each.scope == scope);
  if (nominateGate(state) != NominateGate.open ||
      !nominationsKnown(nominations.state, controller) ||
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

/// Nominate on a pool row (#517): a direct write, so disabled offline
/// through [BgeOnlineOnly], with the connection's reason as its hint. Named
/// for its game to a screen reader, as its row names it ([gameName], #851).
///
/// Where the row is nominated already, or its game in the lineup, for
/// everything it offers ([already]), it reads Nominated with a check and is
/// named "Nominated: " the game, so the row has one control, not a marker
/// and a button that say the same thing (#947).
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
class NominateButton extends StatefulWidget {
  const NominateButton({
    required this.game,
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
class TakeBackButton extends StatefulWidget {
  const TakeBackButton({
    required this.game,
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
  State<TakeBackButton> createState() => TakeBackButtonState();
}

class TakeBackButtonState extends State<TakeBackButton>
    with HeldPress<TakeBackButton> {
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

    return BgeOnlineOnly(
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
          key: widget.buttonKey ?? EventDetailScreen.poolTakeBackKey(game.id),
          focusNode: focusNode,
          onPressed: onPressed,
          icon: inert
              ? const HeldSpinner()
              : const Icon(Icons.remove_circle_outline),
          label: Text(l10n.eventsGamesTakeBack),
        ),
      ),
    );
  }
}
