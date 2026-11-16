import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_actions_bloc.dart';
import 'package:events/src/bloc/event_actions_state.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/nomination_row_controls.dart';
import 'package:events/src/widgets/pool_row_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What a Games tab quick look is about (#957): one entry of the event's
/// lists, by its id. Equal by what it names, so the tab can hold a row's
/// focus and where the row left from by it. #519 adds a lineup entry.
sealed class EventGameEntry extends Equatable {
  const EventGameEntry();

  @override
  bool get stringify => true;
}

/// A copy in the games pool, by the offered game's id.
final class OfferedCopyEntry extends EventGameEntry {
  const OfferedCopyEntry(this.offeredGameId);

  final String offeredGameId;

  @override
  List<Object?> get props => [offeredGameId];
}

/// A nomination for the lineup, by its id.
final class NominationEntry extends EventGameEntry {
  const NominationEntry(this.nominationId);

  final String nominationId;

  @override
  List<Object?> get props => [nominationId];
}

/// Opens [entry]'s [EventGameQuickLook] over the event's screen (#957),
/// through [showBgePopup]: a sheet at `compact` and a dialog from `medium`
/// up, on the root navigator. The pop-up is named [title], the game's name
/// as the row gives it.
///
/// The root navigator is outside the screen, so the quick look is given
/// what the tab reads from [context]: the detail's, the pool's, the
/// nominations' and the actions' blocs, and the tab's controller
/// ([EventGamesTabScope.value]). It reads the blocs live, as the tab does,
/// so a write or a read under it shows at once. The page's own clock builds
/// only the page, so the quick look listens for its ticks through the
/// controller ([EventGamesTabController.clockTicks]) and builds again at the
/// same boundaries, reading the same clock. The screen provides all four
/// blocs wherever the tab is built: the Games tab exists only where the
/// screen has actions, and the tab's scope reads the pool and the
/// nominations itself.
///
/// The tab knows a quick look is open until it closes
/// ([EventGamesTabController.quickLookOpened]), and its lists hand no focus
/// on meanwhile. Completes once it has closed, or has gone under a page
/// View game opened.
Future<void> showEventGameQuickLook(
  BuildContext context, {
  required EventGameEntry entry,
  required String title,
}) async {
  final controller = EventGamesTabScope.of(context);
  final detail = context.read<EventDetailBloc>();
  final games = context.read<EventGamesBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final actions = context.read<EventActionsBloc>();
  controller.quickLookOpened();
  try {
    await showBgePopup<void>(
      context,
      semanticLabel: title,
      builder: (popup) => MultiBlocProvider(
        providers: [
          BlocProvider<EventDetailBloc>.value(value: detail),
          BlocProvider<EventGamesBloc>.value(value: games),
          BlocProvider<EventNominationsBloc>.value(value: nominations),
          BlocProvider<EventActionsBloc>.value(value: actions),
        ],
        child: EventGamesTabScope.value(
          controller: controller,
          child: EventGameQuickLook(entry: entry, title: title),
        ),
      ),
    );
  } finally {
    controller.quickLookClosed();
  }
}

/// One entry of the event's Games tab in a pop-up (#957): what the row holds
/// and more, about the game's place in this event rather than the game, as
/// Home's quick look is (#707). Opened through [showEventGameQuickLook],
/// which gives it the blocs and the controller it reads; its scroll view
/// needs the bounded box the pop-up gives it.
///
/// Every form shares one frame: the cover and the name as its heading, the
/// form's lines as one node and its controls, one online-only note for its
/// writes while offline, the outcome banners, then View game, which opens
/// the game's page ([EventGamesTabController.openGame]) from the quick
/// look's own context, as Home's does: the row it was opened from can leave
/// while it is open. The quick look stays until the page has arrived over it
/// (`showBgePopup`). Without a way to the page there is no View game.
///
/// ## An offered copy
///
/// The name with its subtitle ([gameName]), the platform and the medium,
/// who brings it, and the live nominations it supplies ([suppliesLive]),
/// named for what each is for as the Nominations list names them
/// ([nominationScopeName]), or that it supplies none, where the nominations
/// are known ([nominationsKnown]). What follows the clock, Nominate's
/// choices and the dates' names, moves on as the page does.
/// Then Nominate and Take back where the row builds them, under the row's
/// rules ([poolRowGates]): each disabled offline, saying why, with one
/// [BgeOnlineOnlyNote] under them, held through its own press, and sent only
/// once a running detail read has ended ([nominateGame], [takeBackGame]).
/// Take back arms the tab's hand-off as the row's does
/// ([EventGamesTabController.armTakeBack]).
///
/// ## A nomination
///
/// The game's name; then, as one node, every line the nomination's row says
/// under it ([nominationLines]): its platform, who nominated it, whose copy
/// it is, whether it is for the whole event or one date, where it stands,
/// its tally, spoken without the symbols between the counts, how the event
/// counts Interested, the viewer's vote where no vote control shows it, when
/// voting closes, and why it is paused. Under them, at full width, the
/// viewer's vote while it is open ([nominationVoteControl]); then *Who
/// voted*, Withdraw and a host's decisions, as the row builds them, from the
/// same inputs ([nominationRowInputs]) and under the same rules: each write
/// disabled offline, saying why, with one [BgeOnlineOnlyNote] under them
/// where the vote's own doesn't say it, held through its own press, and sent
/// only once a running detail read has ended ([withdrawNomination],
/// [decideNomination], [sendVote]). *Who voted* opens its list over the
/// quick look and takes focus back as it closes. What follows the clock, the
/// deadline's line and the dates' names, moves on as the page does.
///
/// A write's answer takes the nomination's place, so the quick look stays,
/// as Withdrawn or as decided, and the button whose write it was goes with
/// it. Focus stays in the quick look: once the frame that took the button
/// away has ended, the lines take it, as one node, which reads the new
/// status, as the row's head does on the row. They take it only while focus
/// is free then, on nothing, on the quick look, or still on the button, and
/// however the button was pressed, a screen reader's activation included.
/// They are no stop of their own: Tab goes on from them, and they can't
/// take focus again until the next such write hands it to them. Their ring
/// shows for focus a key press gave, and not for a press of a mouse or a
/// trackpad on the button ([BgePointerFocus]). A write that leaves its
/// button there, refused or failed, leaves focus on it.
///
/// ## Outcomes
///
/// The page's footer says how a write went, under the pop-up's barrier,
/// which hides it from a screen reader. So under its controls the quick
/// look shows the same banners ([EventPoolOutcomeBanner],
/// [EventNominationsOutcomeBanner]) for the outcomes that land while it is
/// open. An offered copy's shows the pool's, for Take back, and the
/// nominations', for Nominate; a nomination's, the nominations', its own
/// list's. An outcome already showing as it opened isn't said again. The
/// footer still shows each, under the barrier, so a screen reader hears it
/// once.
///
/// ## Its entry leaves
///
/// Where the pool no longer holds the copy, taken back from here or by
/// anyone else, or the nominations no longer hold the nomination, as a read
/// finds, or the event is no longer shown, it says so in a live region,
/// under the heading, and offers nothing to press, as Home's does when its
/// game goes (#707). As it closes, the tab hands focus to the row in the
/// entry's place ([EventGamesTabController.focusAfterQuickLook]).
class EventGameQuickLook extends StatefulWidget {
  const EventGameQuickLook({
    required this.entry,
    required this.title,
    super.key,
  });

  final EventGameEntry entry;

  /// The game's name as the row gave it: the heading until the entry is
  /// found.
  final String title;

  @override
  State<EventGameQuickLook> createState() => _EventGameQuickLookState();
}

class _EventGameQuickLookState extends State<EventGameQuickLook> {
  /// The pool's outcome showing as the quick look opened, not said again.
  EventGamesOutcome? _poolOpenedWith;

  /// The nominations' outcome showing as it opened, not said again.
  EventNominationsOutcome? _nominationsOpenedWith;

  /// The copy as the pool last held it, for the heading once it has gone.
  OfferedGame? _copy;

  /// The nomination as the nominations last held it, for the heading once
  /// it has gone.
  EventNomination? _nomination;

  /// Holds the quick look's Take back, which the row's own area can't, as
  /// one node holds one control.
  final FocusNode _takeBackArea = FocusNode(
    debugLabel: 'Quick look take back',
    canRequestFocus: false,
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    _poolOpenedWith = context.read<EventGamesBloc>().state.outcome;
    _nominationsOpenedWith = context.read<EventNominationsBloc>().state.outcome;
  }

  @override
  void dispose() {
    _takeBackArea.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Built again as the screen's clock passes a boundary, which no bloc
    // says: a date starting, a deadline passing (#957).
    listenable: EventGamesTabScope.of(context).clockTicks,
    builder: (context, _) => _blocs(context),
  );

  /// The form [EventGameQuickLook.entry] takes, built from the blocs as they
  /// stand.
  Widget _blocs(
    BuildContext context,
  ) => BlocBuilder<EventDetailBloc, EventDetailState>(
    builder: (context, detail) => BlocBuilder<EventGamesBloc, EventGamesState>(
      builder: (context, games) =>
          BlocBuilder<EventNominationsBloc, EventNominationsState>(
            builder: (context, nominations) =>
                BlocBuilder<EventActionsBloc, EventActionsState>(
                  builder: (context, actions) => switch (widget.entry) {
                    OfferedCopyEntry(:final offeredGameId) => _offeredCopy(
                      context,
                      offeredGameId,
                      detail: detail,
                      games: games,
                      nominations: nominations,
                      acting: eventScreenActing(actions),
                    ),
                    NominationEntry(:final nominationId) => _nominationOf(
                      context,
                      nominationId,
                      detail: detail,
                      games: games,
                      nominations: nominations,
                      acting: eventScreenActing(actions),
                    ),
                  },
                ),
          ),
    ),
  );

  /// The pool's banner, for an outcome that landed since the quick look
  /// opened, else null.
  Widget? _poolOutcome({
    required EventGamesState games,
    required EventNominationsState nominations,
    required String? viewerId,
    required Map<String, String?> names,
  }) {
    final pool = games.outcome;
    if (pool == null ||
        identical(pool, _poolOpenedWith) ||
        !EventPoolOutcomeBanner.says(pool)) {
      return null;
    }
    return EventPoolOutcomeBanner(
      outcome: pool,
      nominations: nominations.nominations,
      viewerId: viewerId,
      names: names,
    );
  }

  /// The nominations' banner, for an outcome that landed since the quick
  /// look opened, else null.
  Widget? _nominationsOutcome(EventNominationsState nominations) {
    final nominated = nominations.outcome;
    if (nominated == null || identical(nominated, _nominationsOpenedWith)) {
      return null;
    }
    return EventNominationsOutcomeBanner(outcome: nominated);
  }

  /// The quick look of the offered copy [id].
  Widget _offeredCopy(
    BuildContext context,
    String id, {
    required EventDetailState detail,
    required EventGamesState games,
    required EventNominationsState nominations,
    required bool acting,
  }) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final controller = EventGamesTabScope.of(context);
    final shown = detail is EventDetailReady
        ? games.games.where((game) => game.id == id).firstOrNull
        : null;
    final copy = _copy = shown ?? _copy;
    final name = copy == null
        ? widget.title
        : gameName(l10n, copy.title, copy.subtitle);
    if (shown == null || detail is! EventDetailReady) {
      return _QuickLookFrame(
        thumbnail: copy?.thumbnail,
        name: name,
        gone: l10n.eventsQuickLookCopyGone,
      );
    }

    final now = controller.clock();
    final names = poolNames(detail.detail);
    final viewerId = detail.detail.attendance?.id;
    final gates = poolRowGates(
      l10n,
      game: shown,
      detail: detail,
      games: games,
      nominations: nominations,
      controller: controller,
      names: names,
      acting: acting,
      now: now,
    );
    final medium = switch (shown.medium) {
      GameMedium.physical => l10n.eventsGamesMediumPhysical,
      GameMedium.digital => l10n.eventsGamesMediumDigital,
      null => null,
    };
    // What each live nomination the copy supplies is for ([suppliesLive]),
    // in the order Nominate offers them: the whole event, then the dates.
    final nominated = nominations.nominations;
    final occurrences = detail.detail.snapshot.occurrences;
    final scopes = [
      for (final occurrenceId in [
        null,
        for (final date in occurrences) date.id,
      ])
        if (suppliesLive(
          shown,
          nominated,
          scope: occurrenceId == null
              ? const WholeEventScope()
              : DateScope(occurrenceId),
        ))
          ?nominationScopeName(
            context,
            occurrenceId,
            occurrences: occurrences,
            now: now,
          ),
    ];
    // None supplied says so only where the nominations say what a copy
    // supplies.
    final supplies = scopes.isNotEmpty
        ? l10n.eventsQuickLookSupplies(
            scopes.join(l10n.eventsDetailSpokenSeparator),
          )
        : !suppliesLive(shown, nominated) &&
              nominationsKnown(nominations, controller)
        ? l10n.eventsQuickLookSuppliesNone
        : null;
    final nominate = gates.nominate;
    final takeBack = gates.takeBack;
    final notGoing = nominate?.notGoing;
    final openGame = controller.openGame;

    return _QuickLookFrame(
      thumbnail: shown.thumbnail,
      name: name,
      lines: [
        if (medium == null)
          Text(shown.platformName, style: quiet)
        else
          Text(
            l10n.eventsGamesWhere(shown.platformName, medium),
            semanticsLabel: l10n.eventsGamesWhereSpoken(
              shown.platformName,
              medium,
            ),
            style: quiet,
          ),
        Text(gates.who, style: quiet),
        if (supplies != null) Text(supplies, style: quiet),
      ],
      controls: [
        if (nominate != null)
          NominateButton(
            buttonKey: EventDetailScreen.quickLookNominateKey,
            game: shown,
            unread: nominate.unread,
            notGoing: notGoing,
            already: nominate.already,
            enabled: nominate.enabled,
            runOver: nominate.runOver,
            onPressed: () =>
                nominateGame(context, shown, clock: controller.clock),
          ),
        if (takeBack != null)
          TakeBackButton(
            buttonKey: EventDetailScreen.quickLookTakeBackKey,
            game: shown,
            area: _takeBackArea,
            inert: takeBack.inert,
            enabled: takeBack.enabled,
            runOver: takeBack.runOver,
            onPressed: () {
              // Armed by the press itself, however it came, as the row's is.
              controller.armTakeBack(shown.id);
              return takeBackGame(
                context,
                controller,
                shown,
                viewerId: viewerId,
                names: names,
              );
            },
          ),
      ],
      note: notGoing,
      // Both are writes.
      offlineNote: nominate != null || takeBack != null,
      // The pool's, for Take back, then the nominations', for Nominate.
      outcomes: [
        ?_poolOutcome(
          games: games,
          nominations: nominations,
          viewerId: viewerId,
          names: names,
        ),
        ?_nominationsOutcome(nominations),
      ],
      onOpenGame: openGame == null
          ? null
          : () => openGame(this.context, shown.gameId),
    );
  }

  /// The quick look of the nomination [id].
  Widget _nominationOf(
    BuildContext context,
    String id, {
    required EventDetailState detail,
    required EventGamesState games,
    required EventNominationsState nominations,
    required bool acting,
  }) {
    final l10n = EventsLocalizations.of(context);
    final controller = EventGamesTabScope.of(context);
    final shown = detail is EventDetailReady
        ? nominations.nominations.where((each) => each.id == id).firstOrNull
        : null;
    final nomination = _nomination = shown ?? _nomination;
    if (shown == null || detail is! EventDetailReady) {
      return _QuickLookFrame(
        thumbnail: nomination?.thumbnail,
        name: nomination?.title ?? widget.title,
        gone: l10n.eventsQuickLookNominationGone,
      );
    }

    final openGame = controller.openGame;
    return _NominationLook(
      nomination: shown,
      viewerId: detail.detail.attendance?.id,
      names: poolNames(detail.detail),
      inputs: nominationRowInputs(
        nomination: shown,
        detail: detail,
        state: nominations,
        pool: games.games,
        poolRead: controller.poolRead(games),
        acting: acting,
      ),
      now: controller.clock(),
      // Its own list's: every write in it is a nominations write.
      outcomes: [?_nominationsOutcome(nominations)],
      onOpenGame: openGame == null
          ? null
          : () => openGame(this.context, shown.gameId),
    );
  }
}

/// A nomination's quick look (#957): see "A nomination" on
/// [EventGameQuickLook]. Built again with the nomination as each read or
/// write leaves it, so it can tell when the write one of its buttons sent
/// has ended, as the nomination's row does.
class _NominationLook extends StatefulWidget {
  const _NominationLook({
    required this.nomination,
    required this.viewerId,
    required this.names,
    required this.inputs,
    required this.now,
    required this.outcomes,
    required this.onOpenGame,
  });

  final EventNomination nomination;

  /// The viewer's roster row id, where they have one.
  final String? viewerId;

  /// The roster's names, by row id.
  final Map<String, String?> names;

  /// What it is built from, as the row is ([nominationRowInputs]).
  final NominationRowInputs inputs;
  final DateTime now;

  /// The banners of the outcomes that landed while it is open.
  final List<Widget> outcomes;

  /// Opens the game's page.
  final VoidCallback? onOpenGame;

  /// Whether it carries the button that sends [write]: Withdraw, or one of
  /// a host's decisions.
  bool offers(NominationWrite write) => offersNominationWrite(
    write,
    nomination,
    inputs.writes,
    viewerId: viewerId,
  );

  @override
  State<_NominationLook> createState() => _NominationLookState();
}

class _NominationLookState extends State<_NominationLook>
    with BgePointerFocus<_NominationLook> {
  /// The lines, as one node: where focus goes once the button whose write
  /// just ended has gone with it. They take focus only then, and are no stop
  /// of their own.
  final FocusNode _lines = FocusNode(
    debugLabel: 'Quick look nomination',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Holds each write button, Withdraw and a host's decisions, by the write
  /// it sends, so the quick look can tell whether one holds focus.
  final Map<NominationWrite, FocusNode> _areas = {
    for (final write in [
      NominationWrite.withdraw,
      for (final decision in NominationDecision.values) decision.write,
    ])
      write: FocusNode(
        debugLabel: 'Quick look ${write.name}',
        canRequestFocus: false,
        skipTraversal: true,
      ),
  };

  /// The write a button's press sent, which hasn't ended yet.
  NominationWrite? _sent;

  @override
  void didUpdateWidget(_NominationLook oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Built again with no nominations write out: the write the press sent
    // has ended, and its answer, if any, is in this quick look.
    final sent = _sent;
    if (sent == null || widget.inputs.writes.busy) return;
    _sent = null;
    // Its button stays, as after a refusal, and keeps its own focus.
    if (widget.offers(sent)) return;
    // The button is still built, and goes with this frame, as may the
    // other write buttons.
    final held = _areas.values.any((area) => area.hasFocus)
        ? FocusManager.instance.primaryFocus
        : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusIsFree(context, untouched: held)) return;
      _lines
        ..canRequestFocus = true
        ..requestFocus();
    });
  }

  @override
  void dispose() {
    _lines.dispose();
    for (final area in _areas.values) {
      area.dispose();
    }
    super.dispose();
  }

  /// The press of the button that sends [write], Withdraw or a host's
  /// decision: [send] asks, and sends it ([withdrawNomination],
  /// [decideNomination]). Completes true when the write was sent, which arms
  /// the hand-off as it ends.
  Future<bool> _pressed(
    NominationWrite write,
    Future<bool> Function() send,
  ) async {
    final sent = await send();
    if (sent && mounted) _sent = write;
    return sent;
  }

  void _linesFocusChanged(bool focused) {
    if (focused) return;
    // A stop only while it holds the focus handed to it. Once this change
    // has been told: a node marked while the focus manager tells its nodes
    // is cleared with them, and its Focus never hears.
    scheduleMicrotask(() {
      if (mounted && !_lines.hasFocus) _lines.canRequestFocus = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nomination = widget.nomination;
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final viewerId = widget.viewerId;
    final inputs = widget.inputs;
    final writes = inputs.writes;
    final control = nominationVoteControl(
      context,
      nomination,
      voting: inputs.voting,
      viewerId: viewerId,
    );
    // The button that sends [write], labelled [label] and named to a
    // screen reader [named], on [key].
    Widget button(
      NominationWrite write, {
      required Key key,
      required String label,
      required String named,
      required IconData icon,
      required Future<bool> Function() send,
    }) => NominationWriteButton(
      // Keyed by its write, so each keeps its own state and focus as the
      // others come and go.
      key: ValueKey<NominationWrite>(write),
      buttonKey: key,
      label: label,
      named: named,
      icon: icon,
      area: _areas[write]!,
      enabled: writes.enabled,
      runOver: !writes.busy,
      onPressed: () => _pressed(write, send),
      onPointerDown: notePointerPress,
    );
    final title = nomination.title;
    // Withdraw, then a host's decisions (#518), as on the row.
    final buttons = [
      if (offersWithdraw(nomination, writes, viewerId: viewerId))
        button(
          NominationWrite.withdraw,
          key: EventDetailScreen.quickLookWithdrawKey,
          label: l10n.eventsWithdraw,
          named: l10n.eventsWithdrawNamed(title),
          icon: Icons.playlist_remove,
          send: () => withdrawNomination(context, nomination),
        ),
      for (final decision in offeredDecisions(nomination, writes))
        button(
          decision.write,
          key: decision.quickLookKey,
          label: decision.label(l10n),
          named: decision.named(l10n, title),
          icon: decision.icon,
          send: () => decideNomination(
            context,
            nomination,
            decision,
            interestedWeight: inputs.interestedWeight,
          ),
        ),
    ];
    final whoVoted = nomination.votes.isEmpty
        ? null
        : WhoVotedButton(
            buttonKey: EventDetailScreen.quickLookVotersKey,
            nomination: nomination,
            names: widget.names,
            rosterShown: inputs.rosterShown,
            viewerId: viewerId,
          );

    return _QuickLookFrame(
      thumbnail: nomination.thumbnail,
      name: title,
      lines: nominationLines(
        context,
        nomination,
        inputs: inputs,
        viewerId: viewerId,
        names: widget.names,
        voteShown: control != null,
        now: widget.now,
      ),
      // Their own node, which takes focus only when handed it.
      wrapLines: (lines) => BgeFocusRing(
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        suppressed: pointerFocus,
        builder: (context, onFocusChange) => Focus(
          key: EventDetailScreen.quickLookLinesKey,
          focusNode: _lines,
          onFocusChange: (focused) {
            onFocusChange(focused);
            _linesFocusChanged(focused);
          },
          // Inset from the ring, which would otherwise run through the
          // first letter of each line.
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spaceSm),
            child: lines,
          ),
        ),
      ),
      vote: control,
      controls: [?whoVoted, ...buttons],
      // Once for its writes: the vote's says it where it is built.
      offlineNote: buttons.isNotEmpty && control == null,
      outcomes: widget.outcomes,
      onOpenGame: widget.onOpenGame,
    );
  }
}

/// The frame every form of the quick look shares (#957): the cover beside
/// the name, as its heading; then, while the entry is there, [lines] as one
/// node, [vote] under them at full width, [controls] in a row that wraps,
/// [note] under them, drawn only, as their hints say it, and one online-only
/// note while offline where [offlineNote] asks for it, then [outcomes], then
/// View game where [onOpenGame] is given. Where the entry has gone, [gone]
/// in a live region in place of them all, so nothing is left to press.
class _QuickLookFrame extends StatelessWidget {
  const _QuickLookFrame({
    required this.thumbnail,
    required this.name,
    this.gone,
    this.lines = const [],
    this.wrapLines,
    this.vote,
    this.controls = const [],
    this.note,
    this.offlineNote = false,
    this.outcomes = const [],
    this.onOpenGame,
  });

  final String? thumbnail;
  final String name;

  /// Says the entry has left; null while it is there.
  final String? gone;

  final List<Widget> lines;

  /// Wraps the lines inside their one node, as a form whose lines take
  /// focus gives them a node and a ring of their own.
  final Widget Function(Widget lines)? wrapLines;

  /// A nomination's vote, under the lines at full width.
  final Widget? vote;

  /// The entry's other controls, each a node of its own.
  final List<Widget> controls;

  /// Why one of [controls] can't be pressed, which its hint already says.
  final String? note;

  /// Whether one online-only note goes under [controls] while offline: they
  /// hold a write whose reason nothing else under them says.
  final bool offlineNote;

  /// The banners of the outcomes that landed while it is open, each keyed
  /// by its own outcome.
  final List<Widget> outcomes;

  /// Opens the game's page.
  final VoidCallback? onOpenGame;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final gone = this.gone;
    final note = this.note;
    final vote = this.vote;
    final onOpenGame = this.onOpenGame;
    final offline = BgeConnectivityScope.offlineOf(context);
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );

    return SingleChildScrollView(
      key: EventDetailScreen.quickLookKey,
      padding: EdgeInsets.fromLTRB(
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceMd,
        tokens.spaceLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spaceMd,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BgeThumbnail(url: thumbnail),
              const BgeGap.md(axis: Axis.horizontal),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(name, style: theme.textTheme.titleLarge),
                ),
              ),
            ],
          ),
          if (gone != null)
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(gone, key: EventDetailScreen.quickLookGoneKey),
            )
          else ...[
            if (lines.isNotEmpty)
              MergeSemantics(child: wrapLines?.call(column) ?? column),
            ?vote,
            if (controls.isNotEmpty)
              Wrap(
                spacing: tokens.spaceSm,
                runSpacing: tokens.spaceSm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: controls,
              ),
            if (note != null)
              ExcludeSemantics(
                child: Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            // Once for its writes, which each carry it as their hint.
            if (offline && offlineNote) const BgeOnlineOnlyNote(),
            ...outcomes,
            if (onOpenGame != null)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonal(
                  key: EventDetailScreen.quickLookOpenGameKey,
                  onPressed: onOpenGame,
                  child: Text(
                    l10n.eventsQuickLookOpenGame,
                    semanticsLabel: l10n.eventsQuickLookOpenGameNamed(name),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
