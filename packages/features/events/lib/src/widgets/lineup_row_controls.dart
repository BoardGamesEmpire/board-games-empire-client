import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_lineup_bloc.dart';
import 'package:events/src/bloc/event_lineup_event.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_lineup.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/detail/games_date_view.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/add_to_lineup_dialog.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/held_spinner.dart';
import 'package:events/src/widgets/pool_row_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';

/// The dates of [detail] a game can be added to straight away (#519): each
/// still live, proposed or confirmed, whether or not it has started, in
/// their order (`sortOrder`, then id). The server adds to any date of the
/// event, and the host adding what is being played on the night is the add
/// it is for; a date called off or declined takes none. Nominate stops at a
/// date's start ([nominatableDates]); the add doesn't.
List<EventOccurrence> lineupAddDates(EventDetail detail) {
  final dates = [
    for (final date in detail.snapshot.occurrences)
      if (date.status == OccurrenceStatus.proposed ||
          date.status == OccurrenceStatus.confirmed)
        date,
  ];
  return dates..sort((a, b) {
    final order = a.sortOrder.compareTo(b.sortOrder);
    return order != 0 ? order : a.id.compareTo(b.id);
  });
}

/// What a direct add (#519) on [detail] can be for, in [view], the row of
/// dates' choice (#1042), from which the add takes its scope: under one
/// date, that date, while it is live ([lineupAddDates]), and nothing once it
/// is called off; under Every date, the whole event. With no view, as on an
/// event of one date or none, the whole event, then the one date where it
/// is live: the add dialog asks which (#519), where Nominate, on such an
/// event, nominates for the whole event alone ([nominateScopes]).
List<NominateScope> lineupAddScopes(
  EventDetail detail, {
  GamesDateView? view,
}) => switch (view) {
  OneDateView(:final occurrenceId) => [
    for (final date in lineupAddDates(detail))
      if (date.id == occurrenceId) (scope: DateScope(date.id), date: date),
  ],
  EveryDateView() => const [(scope: WholeEventScope(), date: null)],
  null => [
    (scope: const WholeEventScope(), date: null),
    for (final date in lineupAddDates(detail))
      (scope: DateScope(date.id), date: date),
  ],
};

/// What a direct add is in [view], the date view in use (#1042), on
/// [detail]: null where the viewer isn't offered it under that view's mode
/// ([lineupAddGate], [viewMode], #519); otherwise what it can be for
/// ([lineupAddScopes]), none where the view's date was called off, which
/// leaves it offered but with nothing to add for. One rule for the pool's
/// rows, their quick looks, the Lineup sub-tab's Add a game and a press's
/// re-check ([addToLineup]).
List<NominateScope>? lineupAddChoicesIn(
  EventDetailReady detail, {
  required GamesDateView? view,
}) =>
    lineupAddGate(detail, mode: viewMode(detail.detail.snapshot, view)) ==
        LineupAddGate.open
    ? lineupAddScopes(detail.detail, view: view)
    : null;

/// Why a direct add (#519) in [view], the date view in use (#1042), can't be
/// made on [detail], where [lineupAddScopes] offers nothing there: the
/// view's date was called off or declined, so it isn't happening; or its
/// status is one this client can't read, which says only that no game can
/// be added to it. A date that has started still takes one, so neither says
/// anything of time.
String lineupAddClosedReason(
  EventsLocalizations l10n,
  EventDetail detail,
  GamesDateView? view,
) {
  final date = switch (view) {
    OneDateView(:final occurrenceId) =>
      detail.snapshot.occurrences
          .where((each) => each.id == occurrenceId)
          .firstOrNull,
    EveryDateView() || null => null,
  };
  return switch (date?.status) {
    OccurrenceStatus.cancelled ||
    OccurrenceStatus.declined => l10n.eventsLineupAddDateClosed,
    _ => l10n.eventsLineupAddDateUnavailable,
  };
}

/// The longest a filler should run on [s] (#519), for [occurrenceId]'s date
/// or, where it is null, the event as a whole: the date's own rule where it
/// sets one (#1009), else the event's, else none.
int? fillerMaxPlayTimeFor(EventSnapshot s, String? occurrenceId) {
  final date = occurrenceId == null
      ? null
      : s.occurrencePolicies
            ?.where((each) => each.occurrenceId == occurrenceId)
            .firstOrNull;
  return date?.fillerMaxPlayTime ?? s.policy?.fillerMaxPlayTime;
}

/// The date [scope] names, or null for the whole event.
String? _occurrenceOf(NominationScope scope) => switch (scope) {
  WholeEventScope() => null,
  DateScope(:final occurrenceId) => occurrenceId,
};

/// Adds [game], a row of the pool, anyone's copy, straight to the lineup
/// (#519): for the one choice the date view in use as it is pressed offers
/// ([lineupAddChoicesIn], #1042), its date or the whole event, or where
/// there are two, with no row of dates, for the one chosen in
/// [showAddToLineupDialog], which asks too what it is played as, a Filler's
/// longest play, filled in from the rules of the scope chosen
/// ([fillerMaxPlayTimeFor]), and a note. The dialog, the add's outcome and a
/// drop name the game as the row does, with its subtitle ([gameName], #851).
/// Completes true when the add was sent, and false when nothing was: the
/// dialog cancelled, or as below.
///
/// It goes once any running detail read has ended ([readEnded]), for the
/// event as the detail shows it then, whose id a reconcile can have moved
/// (#499). Nothing is sent if, by then, the viewer isn't offered the add
/// under the view's mode ([lineupAddGate], [viewMode]), the game has left
/// the pool, or the choice is no longer offered, as a date called off
/// meanwhile isn't: the page already shows that, and the footer says the add
/// was dropped, or a screen reader would hear nothing happen. So too where
/// the view offers no choice as it is pressed. A date that has started
/// still takes it (#519). The view is the one it was pressed under,
/// whatever is chosen meanwhile, and [clock] names the dates the dialog
/// offers. Whoever brings it not going is the server's to refuse, which the
/// outcome says.
Future<bool> addToLineup(
  BuildContext context,
  OfferedGame game, {
  required DateTime Function() clock,
}) async {
  // Read before anything is awaited: the dialog covers the row, and a
  // rebuild can take this context with it.
  final l10n = EventsLocalizations.of(context);
  final detail = context.read<EventDetailBloc>();
  final pool = context.read<EventGamesBloc>();
  final lineup = context.read<EventLineupBloc>();
  final view = EventGamesTabScope.of(context).dateView;
  final shown = detail.state;
  if (shown is! EventDetailReady) return false;

  void dropped() => lineup.add(
    LineupWriteDropped(
      LineupWrite.add,
      title: game.title,
      subtitle: game.subtitle,
    ),
  );

  final choices = lineupAddChoicesIn(shown, view: view);
  if (choices == null || choices.isEmpty) {
    dropped();
    return false;
  }
  final snapshot = shown.detail.snapshot;
  final chosen = await showAddToLineupDialog(
    context,
    title: gameName(l10n, game.title, game.subtitle),
    scopes: choices,
    now: clock(),
    fillerMaxPlayTimeOf: (scope) =>
        fillerMaxPlayTimeFor(snapshot, _occurrenceOf(scope)),
  );
  if (chosen == null || lineup.isClosed) return false;

  final state = await readEnded(detail);
  if (state is! EventDetailReady || lineup.isClosed) return false;
  final inPool = pool.state.games.any((each) => each.id == game.id);
  // Offered still, under the view's mode, and for the choice made.
  final offered =
      lineupAddChoicesIn(
        state,
        view: view,
      )?.any((each) => _occurrenceOf(each.scope) == chosen.occurrenceId) ??
      false;
  if (!inPool || !offered) {
    dropped();
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (lineup.state.busy) return false;
  lineup.add(
    LineupGameAdded(
      state.detail.snapshot.event.id,
      game,
      occurrenceId: chosen.occurrenceId,
      role: chosen.role,
      notes: chosen.notes,
      maxPlayTime: chosen.role == ScheduledGameRole.filler
          ? chosen.maxPlayTime
          : null,
    ),
  );
  return true;
}

/// The Lineup sub-tab's Add a game (#519): opens the pool's games as the
/// pool holds them while it is open ([showLineupGamePicker]), and adds the
/// one picked ([addToLineup]), by [clock]. Completes true when the add was
/// sent, and false when nothing was: nothing picked, or as [addToLineup]
/// says.
///
/// The add goes from the tab's scope ([EventGamesTabScope.contextOf]), which
/// outlives the sub-tab's header, so a pick isn't lost as a read rebuilds
/// the page under the picker.
Future<bool> pickAndAddToLineup(
  BuildContext context, {
  required DateTime Function() clock,
}) async {
  final scope = EventGamesTabScope.contextOf(context);
  final picked = await showLineupGamePicker(context);
  if (picked == null || !scope.mounted) return false;
  return addToLineup(scope, picked, clock: clock);
}

/// What Add to lineup on a pool row is built with (#519):
/// [AddToLineupButton]'s [AddToLineupButton.closed],
/// [AddToLineupButton.notGoing], [AddToLineupButton.enabled] and
/// [AddToLineupButton.runOver], and whether it is the row's main action
/// (`onRow`): under a host-only view, in Nominate's place, and otherwise its
/// quick look's alone.
typedef AddToLineupGates = ({
  String? closed,
  String? notGoing,
  bool enabled,
  bool runOver,
  bool onRow,
});

/// Add to lineup (#519): a direct write, so disabled offline through
/// [BgeOnlineOnly], with the connection's reason as its hint. Named for its
/// game to a screen reader, as its row names it ([gameName], #851). It adds
/// anyone's copy: the server never asks whether the host owns it.
///
/// Online it is disabled, with the reason as its hint, while the date view's
/// date takes no add, called off or in a status this client can't read
/// ([closed], [lineupAddClosedReason], #1042), else while whoever
/// brings the game isn't going ([notGoing]), which the server refuses: a hint
/// says one thing, and those come in that order. It is disabled with no hint
/// while it may not be pressed for a while ([enabled]).
///
/// Its press opens the add dialog, which hands focus back to it as it
/// closes, just before the add goes out, and a disabled button can't hold
/// focus (#607). So, as Nominate is, it is held through [HeldPress] from its
/// press until its add is over ([runOver]): enabled, ignoring presses and
/// showing a spinner, wherever it would otherwise be unavailable.
class AddToLineupButton extends StatefulWidget {
  const AddToLineupButton({
    required this.game,
    required this.closed,
    required this.notGoing,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
    this.buttonKey,
    super.key,
  });

  final OfferedGame game;

  /// Key on the button itself: the row's
  /// ([EventDetailScreen.poolAddToLineupKey]) where null, or the quick
  /// look's.
  final Key? buttonKey;

  /// Why it can't be pressed in the date view in use, where its date takes
  /// no add: it was called off or declined, or its status is one this client
  /// can't read ([lineupAddClosedReason], #1042, #519). Null otherwise.
  final String? closed;

  /// Why it can't be pressed where whoever brings the game has answered Not
  /// going: the viewer, or someone else. Null where they haven't.
  final String? notGoing;

  /// Whether it may be pressed now, connection and reasons aside: false
  /// while a detail read runs, the screen's own request is out, or a lineup
  /// write is out.
  final bool enabled;

  /// Whether no lineup write is out: once its own add went out, that is
  /// over.
  final bool runOver;

  /// Asks how the game goes in, and sends the add. Completes true when it
  /// was sent, and false when nothing was.
  final Future<bool> Function() onPressed;

  @override
  State<AddToLineupButton> createState() => AddToLineupButtonState();
}

class AddToLineupButtonState extends State<AddToLineupButton>
    with HeldPress<AddToLineupButton> {
  @override
  bool get heldActionOver => widget.runOver;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final closed = widget.closed;
    final notGoing = widget.notGoing;
    final available =
        widget.enabled && !offline && closed == null && notGoing == null;
    // Offline, with its date closed, or not going, it is disabled, pressed
    // or not: no press made it so (#49).
    final held = heldInert(
      available: available,
      disabled: offline || closed != null || notGoing != null,
    );
    // One reason: offline [BgeOnlineOnly] gives its own.
    final reason = offline ? null : closed ?? notGoing;
    final game = widget.game;

    return BgeOnlineOnly(
      showNote: false,
      child: Semantics(
        hint: reason,
        child: BgeInertButton(
          inert: held,
          label: l10n.eventsLineupAddToLineupNamed(
            gameName(l10n, game.title, game.subtitle),
          ),
          onPressed: available || held
              ? () => unawaited(holdPress(widget.onPressed))
              : null,
          builder: (context, focusNode, onPressed) => TextButton.icon(
            key:
                widget.buttonKey ??
                EventDetailScreen.poolAddToLineupKey(game.id),
            focusNode: focusNode,
            onPressed: onPressed,
            // The Lineup sub-tab's Add a game's, the same write: apart from
            // Nominate's, beside it in a quick look.
            icon: held ? const HeldSpinner() : const Icon(Icons.add),
            label: Text(l10n.eventsLineupAddToLineup),
          ),
        ),
      ),
    );
  }
}
