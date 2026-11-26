import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_lineup_state.dart';
import 'package:events/src/detail/event_lineup.dart';
import 'package:events/src/detail/nominate_scopes.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_game_quick_look.dart';
import 'package:events/src/widgets/event_game_row_head.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_row_lines.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/held_spinner.dart';
import 'package:events/src/widgets/lineup_row_controls.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the Games tab's Lineup sub-tab shows (#519).
enum EventLineupBody {
  /// The server won't show this viewer the lineup.
  hidden,

  /// Waiting for the first answer, or for the event's own read after the
  /// lineup's found it gone.
  loading,

  /// The read failed, with no games read before. Try again reads it again.
  failed,

  /// No game is in the lineup.
  empty,

  /// The lineup's games, grouped by date.
  rows,
}

/// What a lineup game's row and its quick look say of its role (#519):
/// Primary, or Filler, with the longest it should run beside it where the
/// host set one. Null for a role this client can't read, which says nothing
/// rather than guessing.
String? lineupRoleLine(EventsLocalizations l10n, LineupGame game) =>
    switch (game.role) {
      ScheduledGameRole.primary => l10n.eventsLineupRolePrimary,
      ScheduledGameRole.filler => switch (game.maxPlayTime) {
        final minutes? when minutes > 0 => l10n.eventsLineupRoleFillerUpTo(
          minutes,
        ),
        _ => l10n.eventsLineupRoleFiller,
      },
      ScheduledGameRole.unknown => null,
    };

/// What a lineup game's row and its quick look say of who brings it (#519),
/// as a pool row says it of an offered copy: the viewer, where the copy is
/// their own, by their roster row [viewerId]; else the supplier by the
/// roster's name for them ([names]), else the name the server served with
/// the game, else "this person".
String lineupSupplierLine(
  EventsLocalizations l10n,
  LineupGame game, {
  required String? viewerId,
  required Map<String, String?> names,
}) => game.supplierAttendeeId == viewerId
    ? l10n.eventsLineupYouBring
    : l10n.eventsLineupBrings(
        names[game.supplierAttendeeId] ??
            game.supplierName ??
            l10n.eventsAttendeeSomeoneStart,
      );

/// The Lineup sub-tab of an event's Games tab (#519, #945): the games the
/// event will play, for the event as a whole and for its dates, as [groups]
/// holds them in the date view the row of dates chose ([lineupGroupsFor],
/// #1042). Under a date, that date's, then the event's own; under Every
/// date, the event's own, then any whose date the event no longer lists,
/// which no date's view holds; on an event with no row, the event's own
/// first, then its date's, then any whose date it no longer lists. None is
/// left out, whatever its date.
///
/// Its slivers, as one group under the sub-tabs' bar, with no heading of
/// their own, as the sub-tab's label names the list (#946). First, for a
/// viewer offered a direct add under the date view's mode ([addScopes],
/// [lineupAddChoicesIn]), Add a game, above every state but the lineup being
/// hidden ([_AddGameButton]). Where a game's
/// date is no longer among the event's ([lineupDrawsHeaders]), each group is
/// headed by what it is for: "Every date", the date's name
/// ([eventDateName]), or that the date is no longer on the event. Each
/// heading is a header to a screen reader. Otherwise the lineup is one list
/// with no headings, and, where the view doesn't say it, under a date or
/// with no row, each of the event's own games says on its row that it is
/// for every date ([lineupMarksEveryDate]).
///
/// The rows are [EventGamesRowLines], one per group, keyed by the lineup
/// game's id, two to a line in an expanded window (#949), and numbered among
/// all the groups' rows, as the page counts them. A row keeps its focus as
/// rows come and go around it in its group, but not as it moves to another
/// group: as when a read of the event drops a date before the lineup is read
/// again, so its games move under the date no longer on the event. It is
/// built anew there, and focus on it falls back to the page. A state is in a
/// [BgeStateSliver], as the other sub-tabs' are. A first read that fails says
/// so here, with Try again; one that fails over games read before leaves
/// them, and is the footer's to say.
///
/// A row is compact (#946): the game's cover, its name with its subtitle
/// ([gameName]), and one status line: what it is played as
/// ([lineupRoleLine]), who brings it ([lineupSupplierLine]), and, with no
/// headings, that it is for every date, joined as the event's other lines
/// are and read without the symbols between them. They are one button, the
/// row's head, which opens the game's quick look (#957, [EventGameRowHead]).
/// Its other control is its main action, Remove from lineup, for those the
/// server lets take a game out ([lineupRemoveButton], #520). As the quick
/// look closes, focus goes back to the
/// row's head, or where the row has left, to the head of the row in its
/// place, else to Add a game
/// ([EventGamesTabController.focusAfterQuickLook]).
class EventLineupSection extends StatelessWidget {
  const EventLineupSection({
    required this.body,
    required this.groups,
    required this.detail,
    required this.state,
    required this.controller,
    required this.now,
    required this.names,
    required this.addScopes,
    required this.acting,
    required this.clock,
    super.key,
  });

  final EventLineupBody body;

  /// The lineup's games by date, while [body] is rows.
  final List<LineupGroup> groups;
  final EventDetailReady detail;
  final EventLineupState state;

  /// The tab's own state: the focus nodes of each row, and the date view
  /// (#1042), which decides the headings and the marks.
  final EventGamesTabController controller;

  /// The screen's clock, which names each date.
  final DateTime now;

  /// The roster's names, by row id, which name who brings each game.
  final Map<String, String?> names;

  /// What a direct add can be for in the date view (#519,
  /// [lineupAddChoicesIn]): null where the viewer isn't offered one, which
  /// builds no Add a game; empty where the view's date takes no add, called
  /// off or in a status this client can't read, which disables it, saying
  /// why ([lineupAddClosedReason]).
  final List<NominateScope>? addScopes;

  /// Whether the screen's own request is out, or the event is deleted.
  final bool acting;

  /// The screen's clock, read as an add is pressed and again as it is sent.
  final DateTime Function() clock;

  /// Key on the sliver that holds Add a game.
  static const _addKey = ValueKey<String>('event_lineup.add');

  /// Key on the sliver of what the lineup shows, so Add a game coming or
  /// going above it never builds it anew.
  static const _bodyKey = ValueKey<String>('event_lineup.body');

  @override
  Widget build(BuildContext context) {
    final addScopes = this.addScopes;
    return SliverMainAxisGroup(
      slivers: [
        if (addScopes != null && body != EventLineupBody.hidden)
          SliverToBoxAdapter(
            key: _addKey,
            child: _AddGameButton(
              area: controller.lineupAddArea,
              closed: addScopes.isEmpty
                  ? lineupAddClosedReason(
                      EventsLocalizations.of(context),
                      detail.detail,
                      controller.dateView,
                    )
                  : null,
              // As the tab's other writes are, and not while another lineup
              // write is out.
              enabled: !detail.reading && !acting && !state.busy,
              runOver: !state.busy,
              onPressed: () => pickAndAddToLineup(context, clock: clock),
            ),
          ),
        KeyedSubtree(key: _bodyKey, child: _body(context)),
      ],
    );
  }

  /// What the lineup shows: a state, or its rows.
  Widget _body(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    return switch (body) {
      EventLineupBody.hidden => BgeStateSliver(
        child: BgeEmptyState(
          icon: Icons.visibility_off_outlined,
          title: l10n.eventsLineupHiddenTitle,
        ),
      ),
      EventLineupBody.loading => BgeStateSliver(
        child: BgeLoadingState(label: l10n.eventsLineupLoading),
      ),
      EventLineupBody.failed => BgeStateSliver(
        child: BgeErrorState(
          icon: Icons.cloud_off_outlined,
          title: l10n.eventsLineupFailedTitle,
          body: l10n.eventsGamesFailedBody,
          retryLabel: l10n.eventsRefreshRetry,
          retryProgressLabel: l10n.eventsRefreshInProgress,
          retryKey: EventDetailScreen.lineupRetryKey,
          retrying: state.refreshing,
          onRetry: () => retryEventLineup(context),
        ),
      ),
      EventLineupBody.empty => BgeStateSliver(
        child: BgeEmptyState(
          title: l10n.eventsLineupEmptyTitle,
          body: l10n.eventsLineupEmptyBody,
        ),
      ),
      EventLineupBody.rows => _rows(context, l10n),
    };
  }

  /// Each group's rows, under its heading where the lineup draws them.
  Widget _rows(BuildContext context, EventsLocalizations l10n) {
    final dates = detail.detail.snapshot.occurrences;
    final view = controller.dateView;
    final headers = lineupDrawsHeaders(groups, dates, view: view);
    final marks = lineupMarksEveryDate(view, headers: headers);
    final viewerId = detail.detail.attendance?.id;
    final slivers = <Widget>[];
    // The rows above each group's, which its rows are numbered on from.
    var before = 0;
    for (final (index, group) in groups.indexed) {
      // Keyed by what the group is for, so each keeps its place, and its
      // rows their focus, as a group above it comes or goes.
      final id = '${group.kind.name}_${group.date?.id ?? ''}';
      if (headers) {
        slivers.add(
          SliverToBoxAdapter(
            key: ValueKey<String>('event_lineup.header_$id'),
            child: _GroupHeader(
              title: switch (group) {
                (kind: LineupGroupKind.date, date: final date?, games: _) =>
                  eventDateName(context, date, now: now),
                (kind: LineupGroupKind.goneDate, date: _, games: _) =>
                  l10n.eventsLineupDateGone,
                _ => l10n.eventsLineupEveryDate,
              },
              first: index == 0,
            ),
          ),
        );
      }
      slivers.add(
        EventGamesRowLines<LineupGame>(
          key: ValueKey<String>('event_lineup.rows_$id'),
          items: group.games,
          firstIndex: before,
          keyOf: (game) => EventDetailScreen.lineupRowKey(game.id),
          identityOf: (game) => LineupEntry(game.id),
          itemBuilder: (context, game) => _LineupRow(
            game: game,
            area: controller.lineupArea(game.id),
            head: controller.rowHeadFocus(LineupEntry(game.id)),
            role: lineupRoleLine(l10n, game),
            supplier: lineupSupplierLine(
              l10n,
              game,
              viewerId: viewerId,
              names: names,
            ),
            // Where nothing else says it, the event's own games say they are
            // for every date (#519, #1042).
            everyDate: marks && game.occurrenceId == null,
            // Remove from lineup, for those offered it (#520).
            action: lineupRemoveButton(
              context,
              game: game,
              detail: detail,
              state: state,
              acting: acting,
              now: now,
              clock: clock,
            ),
          ),
        ),
      );
      before += group.games.length;
    }
    return SliverMainAxisGroup(slivers: slivers);
  }
}

/// The heading over one group of the lineup's games: what it is for. Spaced
/// from the rows above it, but for the first.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.first});

  final String title;

  /// Whether it heads the first group, with nothing above it to space from.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        top: first ? 0 : tokens.spaceLg,
        bottom: tokens.spaceXs,
      ),
      child: Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
    );
  }
}

/// One game of the lineup (#519), compact (#946): its picture, its name, and
/// one status line, what it is played as, who brings it and, where the
/// lineup has no headings, that it is for every date, "Filler, up to 20
/// minutes · Ada is bringing this · Every date", spoken with commas; as one
/// button, the row's head, which opens its quick look (#957,
/// [EventGameRowHead]). Its other control is its main action, Remove from
/// lineup, under the head where the viewer is offered it (#520).
class _LineupRow extends StatelessWidget {
  const _LineupRow({
    required this.game,
    required this.area,
    required this.head,
    required this.role,
    required this.supplier,
    required this.everyDate,
    required this.action,
  });

  final LineupGame game;

  /// Holds the whole row, so a row that leaves can say it held focus
  /// ([EventGamesTabController.lineupChanged]).
  final FocusNode area;

  /// The focus of the row's head ([EventGamesTabController.rowHeadFocus]).
  final FocusNode head;

  /// What it is played as ([lineupRoleLine]), where this client can say.
  final String? role;

  /// Who brings it ([lineupSupplierLine]).
  final String supplier;

  /// Whether it says it is for every date.
  final bool everyDate;

  /// Its main action, Remove from lineup (#520), where the viewer is offered
  /// it.
  final RemoveFromLineupButton? action;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // One status line (#946), its parts joined as the event's other lines'
    // are: by a symbol for the eye, which a screen reader would read out, so
    // by a pause for the ear.
    final status = [
      ?role,
      supplier,
      if (everyDate) l10n.eventsGamesEveryDateMark,
    ];
    final action = this.action;

    return Focus(
      focusNode: area,
      includeSemantics: false,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EventGameRowHead(
              key: EventDetailScreen.lineupRowHeadKey(game.id),
              thumbnail: game.thumbnail,
              title: gameName(l10n, game.title, game.subtitle),
              entry: LineupEntry(game.id),
              focusNode: head,
              lines: [
                Text(
                  status.join(l10n.eventsDetailSeparator),
                  semanticsLabel: status.join(
                    l10n.eventsDetailSpokenSeparator,
                  ),
                  style: quiet,
                ),
              ],
            ),
            if (action != null)
              // Outside the head, whose one button can't hold another (#957),
              // and inset past the cover, so the action and its reason line
              // up under the title and the status line.
              Padding(
                padding: EdgeInsetsDirectional.only(
                  start: BgeThumbnail.listExtent + tokens.spaceMd,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    action,
                    if (action.started)
                      // The action's hint already says it.
                      ExcludeSemantics(
                        child: Text(
                          l10n.eventsLineupStartedHint,
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

/// Add a game, at the top of the Lineup sub-tab (#519): opens the pool's
/// games, and adds the one picked straight to the lineup
/// ([pickAndAddToLineup]), for the date view's date or the whole event
/// (#1042), or, with no row of dates, as the add dialog asks.
///
/// A direct write, so disabled offline through [BgeOnlineOnly], with one
/// [BgeOnlineOnlyNote] under it, as the pool's header has. Disabled, with the
/// reason as its hint and under it, where the date view's date takes no add,
/// called off or in a status this client can't read ([closed],
/// [lineupAddClosedReason]); and with nothing to say while it may not be
/// pressed for a while ([enabled]).
///
/// The picker and then the dialog hand focus back to it as each closes, and
/// a disabled button can't hold focus (#607). So, as Offer games is, it is
/// held through [HeldPress] from its press until its add is over
/// ([runOver]): enabled, ignoring presses and showing a spinner, wherever it
/// would otherwise be unavailable. It is held by [area], where a hand-off
/// with no lineup row left to take focus finds it
/// ([EventGamesTabController.lineupAddArea]).
class _AddGameButton extends StatefulWidget {
  const _AddGameButton({
    required this.area,
    required this.closed,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
  });

  /// Holds the button, so a hand-off can find it.
  final FocusNode area;

  /// Why it can't be pressed in the date view in use, where its date takes
  /// no add ([lineupAddClosedReason]). Null otherwise.
  final String? closed;

  /// Whether it may be pressed, connection and reason aside: false while a
  /// detail read runs, the screen's own request is out, or a lineup write is
  /// out.
  final bool enabled;

  /// Whether no lineup write is out: once its own add went out, that is
  /// over.
  final bool runOver;

  /// Opens the picker, then the add dialog, and sends the add. Completes
  /// true when it was sent, and false when nothing was.
  final Future<bool> Function() onPressed;

  @override
  State<_AddGameButton> createState() => _AddGameButtonState();
}

class _AddGameButtonState extends State<_AddGameButton>
    with HeldPress<_AddGameButton> {
  @override
  bool get heldActionOver => widget.runOver;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final offline = BgeConnectivityScope.offlineOf(context);
    final closed = widget.closed;
    final available = widget.enabled && !offline && closed == null;
    // Offline, or with its date closed, it is disabled, pressed or not: no
    // press made it so (#49).
    final held = heldInert(
      available: available,
      disabled: offline || closed != null,
    );
    // One reason: offline [BgeOnlineOnly] gives its own.
    final reason = offline ? null : closed;

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
                inert: held,
                label: l10n.eventsLineupAdd,
                onPressed: available || held
                    ? () => unawaited(holdPress(widget.onPressed))
                    : null,
                builder: (context, focusNode, onPressed) => FilledButton.icon(
                  key: EventDetailScreen.lineupAddKey,
                  focusNode: focusNode,
                  onPressed: onPressed,
                  icon: held ? const HeldSpinner() : const Icon(Icons.add),
                  label: Text(l10n.eventsLineupAdd),
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
        if (offline) ...[const BgeGap.md(), const BgeOnlineOnlyNote()],
        const BgeGap.md(),
      ],
    );
  }
}
