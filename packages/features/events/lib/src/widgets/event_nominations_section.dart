import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_game_quick_look.dart';
import 'package:events/src/widgets/event_game_row_head.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_row_lines.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/nomination_filters_sheet.dart';
import 'package:events/src/widgets/nomination_row_controls.dart';
import 'package:flutter/material.dart';
import 'package:game_filters/game_filters.dart' show InUseChip, InUseChips;
import 'package:models/domain.dart' hide Visibility;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the Games tab's Nominations section shows (#517).
enum EventNominationsBody {
  /// The server won't show this viewer the nominations.
  hidden,

  /// Waiting for the first answer, or for the event's own read after the
  /// nominations' found it gone.
  loading,

  /// The read failed, with no nominations read before. Try again reads them
  /// again.
  failed,

  /// Nobody has nominated a game.
  empty,

  /// Games are nominated, and the filter leaves none of them.
  noMatches,

  /// The nominations the filter keeps, in the order chosen.
  rows,
}

/// The Nominations section, what an event's Games tab shows on its
/// Nominations sub-tab (#517, #945): the games nominated for the lineup, one
/// row each, those the filter keeps, in the order chosen, newest first
/// unless the viewer chose another.
///
/// Its slivers, as one group under the sub-tabs' bar, with no heading of
/// their own, as the sub-tab's label names the list (#946): the header,
/// while there is something to narrow or the filter narrows (see "Filters
/// and sort"); then the rows ([EventGamesRowLines], keyed by the
/// nomination's id, two to a line in an expanded window, #949) or one state.
/// A state is in a [BgeStateSliver], as the pool's are, which fills the rest
/// of the page and centres it. The style guide keeps a section's state in a
/// [SliverToBoxAdapter] only where something follows the section, whose room
/// the state would take; on its own sub-tab (#945), nothing follows this one. A
/// first read that fails says so here, with Try again; one that fails over
/// nominations read before leaves them and is the footer's to say. With none
/// nominated, it points to the Pool sub-tab only where the viewer is offered
/// Nominate there ([nominateGate]).
///
/// ## Filters and sort
///
/// Every nomination is read, so they are narrowed and ordered on the device
/// (#517), by the [controller]'s filter and order, which outlive a switch to
/// the Details tab. [rows] arrive filtered and sorted.
///
/// The header shows wherever nominations are held to narrow, and wherever
/// the filter narrows, so its chips and Clear filters stay reachable over
/// "No nominations match" and the states it can be left on; never over the
/// wait for a first answer or nominations hidden. It holds, in order:
///
/// - Filters, which opens [showNominationFilters], and Sort, a menu of the
///   orders that marks the one chosen ([NominationSort]). Each puts focus
///   back on itself as what it opened closes.
/// - A chip per filter in use, which removes it ([InUseChips]): its press
///   hands focus to the chip in its place, else the one before it, else
///   Filters, while focus is free.
/// - The count: how many nominations there are, and while the filter
///   narrows, how many of them it keeps, as a live region, so a filter
///   applied is heard.
///
/// "No nominations match" offers Clear filters, which brings every
/// nomination back and hands focus to Filters, as the pool's hands it to
/// People. The order stays as chosen.
///
/// A row the filter no longer keeps once a write or a read has changed it,
/// as one voted on under "Not voted yet", leaves; where it held focus, or
/// its write was the one that changed it, focus goes on to the next row
/// shown ([EventGamesTabController.nominationsChanged]).
///
/// A row is compact (#946): the game's cover, its title and one status line,
/// where it stands and its tally of the votes that count, "Voting · 3 for ·
/// 1 against · 0 interested", spoken with commas. They are read as one node:
/// one button, the row's head, which opens the nomination's quick look
/// (#957, [EventGameRowHead]). Under it, a node of its own, the viewer's vote
/// where they may vote, at the row's full width. The rest is the quick
/// look's ([EventGameQuickLook]): every line a nomination says
/// ([nominationLines]), who nominated it, whose copy it is, what it is for,
/// how the event counts Interested, the viewer's vote where no vote control
/// shows it, when voting closes and why it is paused; then *Who voted*,
/// Withdraw and a host's decisions. The row and its quick look build their
/// controls from the same inputs, under the same rules
/// ([nominationRowInputs]).
///
/// ## Voting
///
/// An open nomination carries the viewer's vote where their actions hold
/// [EventAction.voteGame], they have a row on the roster and the event takes
/// writes ([takesDateWrites]: not cancelled or archived), with the line
/// [voteHintFor] gives above it: the one about offering a game only once
/// [poolRead], since before that the pool can't say what they offer.
///
/// A vote is a direct write: disabled offline (#49), and, as the tab's other
/// writes are, while a detail read runs, whose answer landing after the
/// write would show the event as it was (#589), while the screen's own
/// request is out or the event is deleted ([acting]), and while another
/// nominations write is out. A press waits for any running detail read to
/// end ([readEnded]), then sends only if the event still takes writes, the
/// viewer may still vote and the nomination is still open as the
/// nominations' state holds it; otherwise nothing is sent, and the footer
/// says so. A note goes out with the viewer's vote as that state holds it
/// then; one unchanged sends nothing.
///
/// ## Withdrawing and a host's decisions
///
/// Withdraw, on the viewer's own live nominations ([offersWithdraw]), and a
/// host's Approve, Reject and Close vote (#518), on the status each settles
/// ([offeredDecisions]), are in the nomination's quick look alone (#946),
/// under the rules they had on the row: direct writes, disabled offline,
/// while a detail read runs, while the screen's own request is out and while
/// another nominations write is out; each asks first, waits for any running
/// detail read to end, and sends only if it still may ([withdrawNomination],
/// [decideNomination]). As the quick look closes, focus goes back to the
/// row's head, or where the row has left the rows shown, to the head of the
/// row in its place ([EventGamesTabController.focusAfterQuickLook]).
class EventNominationsSection extends StatelessWidget {
  const EventNominationsSection({
    required this.body,
    required this.rows,
    required this.detail,
    required this.state,
    required this.controller,
    required this.pool,
    required this.poolRead,
    required this.acting,
    required this.now,
    super.key,
  });

  final EventNominationsBody body;

  /// The nominations shown, filtered and sorted, while [body] is rows.
  final List<EventNomination> rows;
  final EventDetailReady detail;
  final EventNominationsState state;

  /// The tab's own state: the nominations' filter and order, and the focus
  /// nodes of the header and of each row.
  final EventGamesTabController controller;

  /// Every game in the pool as last read, whatever its filter keeps: where a
  /// row finds the copy it nominates.
  final List<OfferedGame> pool;

  /// Whether [pool] says what the viewer offers: a read of it has answered,
  /// or it holds games read before.
  final bool poolRead;

  /// Whether the screen's own request is out, or the event is deleted.
  final bool acting;

  /// The screen's clock, which names a date in the header's chips.
  final DateTime now;

  /// Key on the header's sliver, so it keeps its state, and its chips their
  /// focus, as what is under it changes.
  static const _headerKey = ValueKey<String>('event_nominations.header');

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final viewerId = detail.detail.attendance?.id;
    // Over what can be narrowed, and wherever the filter narrows, so its
    // chips and Clear filters can't be stranded; never over the first wait
    // or nominations hidden.
    final header = switch (body) {
      EventNominationsBody.rows || EventNominationsBody.noMatches => true,
      EventNominationsBody.empty ||
      EventNominationsBody.failed => controller.nominationFilter.narrows,
      EventNominationsBody.hidden || EventNominationsBody.loading => false,
    };

    return SliverMainAxisGroup(
      slivers: [
        if (header)
          SliverToBoxAdapter(
            key: _headerKey,
            child: _NominationsHeader(
              controller: controller,
              detail: detail,
              shown: rows.length,
              total: state.nominations.length,
              now: now,
            ),
          ),
        switch (body) {
          EventNominationsBody.hidden => BgeStateSliver(
            child: BgeEmptyState(
              icon: Icons.visibility_off_outlined,
              title: l10n.eventsNominationsHiddenTitle,
            ),
          ),
          EventNominationsBody.loading => BgeStateSliver(
            child: BgeLoadingState(label: l10n.eventsNominationsLoading),
          ),
          EventNominationsBody.failed => BgeStateSliver(
            child: BgeErrorState(
              icon: Icons.cloud_off_outlined,
              title: l10n.eventsNominationsFailedTitle,
              body: l10n.eventsGamesFailedBody,
              retryLabel: l10n.eventsRefreshRetry,
              retryProgressLabel: l10n.eventsRefreshInProgress,
              retryKey: EventDetailScreen.nominationsRetryKey,
              retrying: state.refreshing,
              onRetry: () => retryEventNominations(context),
            ),
          ),
          EventNominationsBody.empty => BgeStateSliver(
            child: BgeEmptyState(
              title: l10n.eventsNominationsEmptyTitle,
              // Pointing to the Pool sub-tab only where the viewer is
              // offered Nominate there.
              body: nominateGate(detail) == NominateGate.open
                  ? l10n.eventsNominationsEmptyBody
                  : null,
            ),
          ),
          EventNominationsBody.noMatches => BgeStateSliver(
            child: BgeEmptyState(
              icon: Icons.search_off_outlined,
              title: l10n.eventsNominationsNoMatches,
              action: OutlinedButton(
                key: EventDetailScreen.nominationsClearFiltersKey,
                focusNode: controller.nominationsClearFiltersFocus,
                onPressed: () => controller.clearNominationFilters(context),
                child: Text(l10n.eventsNominationsClearFilters),
              ),
            ),
          ),
          EventNominationsBody.rows => EventGamesRowLines<EventNomination>(
            items: rows,
            keyOf: (nomination) =>
                EventDetailScreen.nominationRowKey(nomination.id),
            identityOf: (nomination) => NominationEntry(nomination.id),
            itemBuilder: (context, nomination) => _NominationRow(
              area: controller.nominationArea(nomination.id),
              head: controller.rowHeadFocus(NominationEntry(nomination.id)),
              nomination: nomination,
              viewerId: viewerId,
              // The row's rules, which its quick look builds by too (#957).
              voting: nominationRowInputs(
                nomination: nomination,
                detail: detail,
                state: state,
                pool: pool,
                poolRead: poolRead,
                acting: acting,
              ).voting,
            ),
          ),
        },
      ],
    );
  }
}

/// The Nominations section's header (#517): Filters and Sort, a chip per
/// filter in use, and the count. See "Filters and sort" on
/// [EventNominationsSection].
class _NominationsHeader extends StatelessWidget {
  const _NominationsHeader({
    required this.controller,
    required this.detail,
    required this.shown,
    required this.total,
    required this.now,
  });

  final EventGamesTabController controller;
  final EventDetailReady detail;

  /// How many nominations the filter keeps.
  final int shown;

  /// How many nominations are held, whatever the filter keeps.
  final int total;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final filter = controller.nominationFilter;
    final dates = detail.detail.snapshot.occurrences;
    final chips = <InUseChip<NominationFilter>>[
      for (final group in NominationStatusGroup.values)
        if (filter.statuses.contains(group))
          _chip(
            l10n,
            id: 'status_${group.name}',
            label: nominationStatusGroupLabel(l10n, group),
            without: filter.copyWith(
              statuses: {...filter.statuses}..remove(group),
            ),
          ),
      if (filter.scope case final scope?)
        _chip(
          l10n,
          id: 'date',
          label: nominationScopeLabel(context, scope, dates: dates, now: now),
          without: filter.copyWith(clearScope: true),
        ),
      if (filter.mine)
        _chip(
          l10n,
          id: 'mine',
          label: l10n.eventsNominationsMine,
          without: filter.copyWith(mine: false),
        ),
      if (filter.notVotedYet)
        _chip(
          l10n,
          id: 'not_voted',
          label: l10n.eventsNominationsNotVoted,
          without: filter.copyWith(notVotedYet: false),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: tokens.spaceSm,
          runSpacing: tokens.spaceSm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: EventDetailScreen.nominationsFiltersKey,
              focusNode: controller.nominationsFiltersFocus,
              onPressed: () => unawaited(_openFilters(context)),
              icon: const Icon(Icons.tune),
              label: Text(
                l10n.eventsNominationsFilters,
                semanticsLabel: l10n.eventsNominationsFiltersNamed,
              ),
            ),
            _SortMenu(
              sort: controller.nominationSort,
              focusNode: controller.nominationsSortFocus,
              onChanged: controller.setNominationSort,
            ),
          ],
        ),
        // A chip per filter in use, which removes it. Always in the tree,
        // drawing nothing without a chip, so that it is there to hand focus
        // to Filters after its last chip goes. Spaced from above only while
        // it shows chips.
        Padding(
          padding: EdgeInsets.only(top: chips.isEmpty ? 0 : tokens.spaceSm),
          child: InUseChips<NominationFilter>(
            value: filter,
            chips: chips,
            onRemove: (chip) => controller.setNominationFilter(chip.without),
            onEmptied: controller.nominationsFiltersFocus.requestFocus,
          ),
        ),
        // With nothing held there is nothing to count.
        if (total > 0) ...[
          const BgeGap.sm(),
          // A filter applied takes a live region on the text that changed.
          Semantics(
            key: EventDetailScreen.nominationsCountKey,
            container: true,
            liveRegion: filter.narrows,
            child: Text(
              filter.narrows
                  ? l10n.eventsNominationsShown(shown, total)
                  : l10n.eventsNominationsCount(total),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
        const BgeGap.md(),
      ],
    );
  }

  /// The chip [id] for a filter in use, which [without] leaves out.
  InUseChip<NominationFilter> _chip(
    EventsLocalizations l10n, {
    required String id,
    required String label,
    required NominationFilter without,
  }) => (
    id: id,
    key: EventDetailScreen.nominationsInUseKey(id),
    label: label,
    semanticsLabel: null,
    removeLabel: l10n.eventsNominationsFilterRemove(label),
    without: without,
  );

  /// Opens the nominations' filters, and puts focus back on Filters once
  /// they have closed. Mine is offered where the viewer has a row on the
  /// roster, and Not voted yet where they may vote too.
  Future<void> _openFilters(BuildContext context) async {
    final focus = controller.nominationsFiltersFocus;
    final viewer = detail.detail.attendance;
    await showNominationFilters(
      context,
      controller: controller,
      dates: detail.detail.snapshot.occurrences,
      now: now,
      offersMine: viewer != null,
      offersNotVoted:
          viewer != null && detail.actions.contains(EventAction.voteGame),
    );
    // Only where it is still built: a node asked while it isn't would take
    // focus whenever it is built again.
    if (focus.context?.mounted ?? false) focus.requestFocus();
  }
}

/// Sort, and the menu of orders it opens (#517).
///
/// A `MenuAnchor`, never a `DropdownMenu`, whose single-line field clips at
/// 320dp and twice the text, as Collection's sort is. The order chosen is
/// marked in the menu, read as selected, and named on the button, "Sort:
/// Newest", as Collection's is, whose label wraps rather than clips. The
/// menu's panel is held to the screen's width, so a long item wraps rather
/// than being cut at the panel's edge. A pick, or Escape, hands focus back to
/// the button.
///
/// While the menu is open, the down arrow on the button moves into it, to
/// its first order, and the up arrow to its last ([_IntoMenu]).
class _SortMenu extends StatefulWidget {
  const _SortMenu({
    required this.sort,
    required this.focusNode,
    required this.onChanged,
  });

  /// The order chosen.
  final NominationSort sort;
  final FocusNode focusNode;

  /// Called with the order picked.
  final ValueChanged<NominationSort> onChanged;

  @override
  State<_SortMenu> createState() => _SortMenuState();
}

class _SortMenuState extends State<_SortMenu> {
  /// Each order's item in the menu.
  final Map<NominationSort, FocusNode> _items = {
    for (final order in NominationSort.values)
      order: FocusNode(debugLabel: 'Sort by ${order.name}'),
  };

  @override
  void dispose() {
    for (final node in _items.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final sort = widget.sort;

    return MenuAnchor(
      childFocusNode: widget.focusNode,
      crossAxisUnconstrained: false,
      menuChildren: [
        for (final order in NominationSort.values)
          // Merged, so the item's own node carries its selected state.
          MergeSemantics(
            child: Semantics(
              selected: order == sort,
              child: MenuItemButton(
                key: EventDetailScreen.nominationsSortItemKey(order),
                focusNode: _items[order],
                overflowAxis: Axis.vertical,
                // The others keep the check's room, so the labels line up.
                leadingIcon: order == sort
                    ? const Icon(Icons.check)
                    : const Visibility(
                        visible: false,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: Icon(Icons.check),
                      ),
                onPressed: () => widget.onChanged(order),
                child: Text(_sortName(l10n, order)),
              ),
            ),
          ),
      ],
      builder: (context, menu, _) => Actions(
        actions: {
          DirectionalFocusIntent: _IntoMenu(
            menu: menu,
            first: _items[NominationSort.values.first]!,
            last: _items[NominationSort.values.last]!,
          ),
        },
        // Wrapped as Flutter's own SubmenuButton is, so assistive tech hears
        // whether the menu is open. The order is in the label, and not a
        // value too, which would say it twice.
        child: MergeSemantics(
          child: Semantics(
            expanded: menu.isOpen,
            child: OutlinedButton.icon(
              key: EventDetailScreen.nominationsSortKey,
              focusNode: widget.focusNode,
              onPressed: menu.isOpen ? menu.close : menu.open,
              icon: const Icon(Icons.sort),
              label: Text(l10n.eventsNominationsSort(_sortName(l10n, sort))),
            ),
          ),
        ),
      ),
    );
  }
}

/// An arrow key on Sort: into the menu while it is open, down to its [first]
/// item and up to its [last]; otherwise, and for left and right, focus moves
/// as an arrow moves it anywhere.
///
/// Flutter moves focus by an arrow among the controls of the scroll view the
/// focused one is in, while it has any that way, and the menu is drawn over
/// the page, outside it. So with rows under the header, the down arrow on
/// Sort would skip its own open menu for the first control of a row.
class _IntoMenu extends Action<DirectionalFocusIntent> {
  _IntoMenu({required this.menu, required this.first, required this.last});

  final MenuController menu;
  final FocusNode first;
  final FocusNode last;

  @override
  void invoke(DirectionalFocusIntent intent) {
    if (menu.isOpen) {
      switch (intent.direction) {
        case TraversalDirection.down:
          first.requestFocus();
          return;
        case TraversalDirection.up:
          last.requestFocus();
          return;
        case TraversalDirection.left || TraversalDirection.right:
          break;
      }
    }
    primaryFocus?.focusInDirection(intent.direction);
  }
}

/// [sort]'s name, in the Sort menu and on Sort.
String _sortName(EventsLocalizations l10n, NominationSort sort) =>
    switch (sort) {
      NominationSort.newest => l10n.eventsNominationsSortNewest,
      NominationSort.mostSupport => l10n.eventsNominationsSortSupport,
      NominationSort.soonestDeadline => l10n.eventsNominationsSortDeadline,
    };

/// One nomination (#517), compact (#946): its picture, its title and one
/// status line, where it stands and its tally of the votes that count,
/// "Voting · 3 for · 1 against · 0 interested", spoken with commas, as one
/// button, the row's head, which opens its quick look (#957,
/// [EventGameRowHead]). Under both, outside that node and at the row's full
/// width, the viewer's vote while it is open and they may vote ([voting],
/// [nominationVoteControl]); otherwise nothing. The rest of what it says,
/// *Who voted*, Withdraw and a host's decisions are its quick look's.
class _NominationRow extends StatelessWidget {
  const _NominationRow({
    required this.area,
    required this.head,
    required this.nomination,
    required this.viewerId,
    required this.voting,
  });

  /// Holds the whole row, so a row that leaves the rows shown can say it
  /// held focus ([EventGamesTabController.nominationsChanged]), and the row
  /// before or after it can be handed it.
  final FocusNode area;

  /// The focus of the row's head ([EventGamesTabController.rowHeadFocus]).
  final FocusNode head;

  final EventNomination nomination;

  /// The viewer's roster row id, where they have one.
  final String? viewerId;

  /// The viewer's vote, where they may vote ([nominationRowInputs]).
  final NominationVoting? voting;

  @override
  Widget build(BuildContext context) {
    final nomination = this.nomination;
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final status = nominationStatusLabel(l10n, nomination.status);
    final tally = tallyOf(nomination);
    final control = nominationVoteControl(
      context,
      nomination,
      voting: voting,
      viewerId: viewerId,
    );

    return Focus(
      focusNode: area,
      includeSemantics: false,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EventGameRowHead(
              key: EventDetailScreen.nominationRowHeadKey(nomination.id),
              thumbnail: nomination.thumbnail,
              title: nomination.title,
              entry: NominationEntry(nomination.id),
              focusNode: head,
              lines: [
                Text(
                  l10n.eventsNominationStatusLine(
                    status,
                    tally.forCount,
                    tally.againstCount,
                    tally.interestedCount,
                  ),
                  // The symbols between its parts would be read out.
                  semanticsLabel: l10n.eventsNominationStatusLineSpoken(
                    status,
                    tally.forCount,
                    tally.againstCount,
                    tally.interestedCount,
                  ),
                  style: quiet,
                ),
              ],
            ),
            // Under the picture and the line, at the row's full width: the
            // three choices share it, and beside the picture they would have
            // so little that a chosen Interested shrinks to half size at a
            // phone's width and ordinary text.
            if (control != null) ...[const BgeGap.sm(), control],
          ],
        ),
      ),
    );
  }
}
