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
/// form's lines and controls, the outcome banners, then View game, which
/// opens the game's page ([EventGamesTabController.openGame]) from the
/// quick look's own context, as Home's does: the row it was opened from can
/// leave while it is open. The quick look stays until the page has arrived
/// over it (`showBgePopup`). Without a way to the page there is no View
/// game.
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
/// ## Outcomes
///
/// The page's footer says how a write went, under the pop-up's barrier,
/// which hides it from a screen reader. So under its controls the quick
/// look shows the same banners ([EventPoolOutcomeBanner],
/// [EventNominationsOutcomeBanner]) for the outcomes that land while it is
/// open: the pool's, for Take back, and the nominations', for Nominate. An
/// outcome already showing as it opened isn't said again. The footer still
/// shows each, under the barrier, so a screen reader hears it once.
///
/// ## Its entry leaves
///
/// Where the pool no longer holds the copy, taken back from here or by
/// anyone else, or the event is no longer shown, it says so in a live
/// region, under the heading, and offers nothing to press, as Home's does
/// when its game goes (#707). As it closes, the tab hands focus to the row
/// in the copy's place ([EventGamesTabController.focusAfterQuickLook]).
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
  Widget _blocs(BuildContext context) =>
      BlocBuilder<EventDetailBloc, EventDetailState>(
        builder: (context, detail) =>
            BlocBuilder<EventGamesBloc, EventGamesState>(
              builder: (context, games) =>
                  BlocBuilder<EventNominationsBloc, EventNominationsState>(
                    builder: (context, nominations) =>
                        BlocBuilder<EventActionsBloc, EventActionsState>(
                          builder: (context, actions) => switch (widget.entry) {
                            OfferedCopyEntry(:final offeredGameId) =>
                              _offeredCopy(
                                context,
                                offeredGameId,
                                detail: detail,
                                games: games,
                                nominations: nominations,
                                acting: eventScreenActing(actions),
                              ),
                            // Nothing opens one until its row has a head.
                            NominationEntry() => throw UnimplementedError(
                              "A nomination's quick look (#957)",
                            ),
                          },
                        ),
                  ),
            ),
      );

  /// The banners for the outcomes that landed since the quick look opened:
  /// the pool's, then the nominations'.
  List<Widget> _outcomes({
    required EventGamesState games,
    required EventNominationsState nominations,
    required String? viewerId,
    required Map<String, String?> names,
  }) {
    final pool = games.outcome;
    final nominated = nominations.outcome;
    return [
      if (pool != null &&
          !identical(pool, _poolOpenedWith) &&
          EventPoolOutcomeBanner.says(pool))
        EventPoolOutcomeBanner(
          outcome: pool,
          nominations: nominations.nominations,
          viewerId: viewerId,
          names: names,
        ),
      if (nominated != null && !identical(nominated, _nominationsOpenedWith))
        EventNominationsOutcomeBanner(outcome: nominated),
    ];
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
      outcomes: _outcomes(
        games: games,
        nominations: nominations,
        viewerId: viewerId,
        names: names,
      ),
      onOpenGame: openGame == null
          ? null
          : () => openGame(this.context, shown.gameId),
    );
  }
}

/// The frame every form of the quick look shares (#957): the cover beside
/// the name, as its heading; then, while the entry is there, [lines] as one
/// node, [controls] in a row that wraps, [note] under them, drawn only, as
/// their hints say it, and one online-only note while offline, then
/// [outcomes], then View game where [onOpenGame] is given. Where the entry
/// has gone, [gone] in a live region in place of them all, so nothing is
/// left to press.
class _QuickLookFrame extends StatelessWidget {
  const _QuickLookFrame({
    required this.thumbnail,
    required this.name,
    this.gone,
    this.lines = const [],
    this.controls = const [],
    this.note,
    this.outcomes = const [],
    this.onOpenGame,
  });

  final String? thumbnail;
  final String name;

  /// Says the entry has left; null while it is there.
  final String? gone;

  final List<Widget> lines;

  /// The entry's writes, each a node of its own.
  final List<Widget> controls;

  /// Why one of [controls] can't be pressed, which its hint already says.
  final String? note;

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
    final onOpenGame = this.onOpenGame;
    final offline = BgeConnectivityScope.offlineOf(context);

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
              MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines,
                ),
              ),
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
            if (offline && controls.isNotEmpty) const BgeOnlineOnlyNote(),
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
