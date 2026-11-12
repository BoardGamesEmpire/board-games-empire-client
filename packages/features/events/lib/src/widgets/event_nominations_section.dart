import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/confirm_dialog.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/event_section_states.dart';
import 'package:events/src/widgets/held_press.dart';
import 'package:events/src/widgets/nomination_filters_sheet.dart';
import 'package:events/src/widgets/nomination_vote_control.dart';
import 'package:events/src/widgets/nomination_voters_sheet.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_filters/game_filters.dart' show InUseChip, InUseChips;
import 'package:models/domain.dart' hide Visibility;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the Games tab's Nominations section shows under its heading (#517).
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

/// The Nominations section at the head of an event's Games tab, above the
/// pool (#517): the games nominated for the lineup, one row each, those the
/// filter keeps, in the order chosen, newest first unless the viewer chose
/// another.
///
/// Its slivers, as one group: a heading ([EventGamesTabHeading]); then the
/// header, while there is something to narrow or the filter narrows (see
/// "Filters and sort"); then the rows ([BgeKeyedSliverList], keyed by the
/// nomination's id) or one state; then the gap before the pool's own
/// heading. Each state sits in a [SliverToBoxAdapter], not a
/// [BgeStateSliver]: one would fill the rest of the view and push the pool
/// below it. A first read that
/// fails says so here, with Try again; one that fails over nominations read
/// before leaves them and is the footer's to say. With none nominated, it
/// points to the pool below only where the viewer is offered Nominate there
/// ([nominateGate]).
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
/// A row says, top to bottom: the game and its platform; who nominated it;
/// whose copy it is; whether it is for the whole event or one date; where
/// it stands; its tally of the votes that count, with how this event counts
/// Interested where its policy says; the viewer's vote, and whether it
/// counts, where no vote control shows it; when voting closes, while it is
/// open and has a deadline; and why it is paused, while it is. Read as one
/// node.
/// The row's controls come after that node, outside it, so each is a node of
/// its own: the viewer's vote ([NominationVoteControl]), *Who voted*,
/// Withdraw, and a host's decisions.
///
/// Whose copy it is comes from the pool row it was nominated from, and that
/// row's attendee from the roster. The nomination names no attendee of its
/// own (backend#1213), so where the pool no longer holds the row, as when
/// its owner said they aren't coming, it is "whoever brings it". The
/// viewer's own nominations and games say so, as the pool's rows do.
///
/// A deadline is a fixed time, never a countdown (#517). Past it, the row
/// says it stays open until a host closes the vote, since nothing closes it
/// on time yet (backend#797).
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
/// *Who voted*, on every row with a vote, counts every vote, those that don't
/// count included, and opens [showNominationVoters]: counts alone where the
/// roster was read and withheld, and the votes otherwise. Its focus comes
/// back to it as the list closes.
///
/// ## Withdrawing
///
/// The viewer's own nominations carry Withdraw while they are live (open,
/// awaiting approval or paused), where their actions hold
/// [EventAction.nominateGame], they have a row on the roster and the event
/// takes writes ([takesDateWrites]). It is a direct write, disabled as a
/// vote is: offline, saying why once under the row's controls, while a
/// detail read runs, while the screen's own request is out, and while
/// another nominations write is out. It asks first, as a destructive action,
/// since the nomination's votes are lost and nominating the game again
/// starts from none. Then it waits for any running detail read to end, and
/// sends only if the event still takes writes, the viewer may still
/// nominate and the nomination is still theirs and live as the nominations'
/// state holds it; otherwise nothing is sent, and the footer says so
/// ([_withdraw]). It is held, inert, from its press through its withdrawal,
/// as Nominate is, so the focus the dialog hands back to it stays
/// ([_RowWriteButton]).
///
/// A withdrawal's answer takes the row's place, so the row stays, as
/// Withdrawn, or as decided where the server answered that it can't be
/// withdrawn now, and Withdraw goes with its control. Focus stays on the row:
/// once the frame that took Withdraw away has ended, the row's lines take it,
/// as one node, which reads the row's new status. They take it only while
/// focus is free then, on nothing, on the page, or still on Withdraw: a
/// press elsewhere meanwhile keeps its focus. Withdraw's press arms it however
/// it came, so a screen reader's activation, which moves no input focus, is
/// handed on too, and the reader's cursor follows. The lines are no stop of
/// their own: Tab goes on from them, and they can't take focus again until
/// the next withdrawal hands it to them. Their ring shows for focus a key
/// press gave, as a button's does, and not for a press of a mouse or a
/// trackpad on Withdraw ([BgePointerFocus]). A withdrawal that leaves the row
/// live, refused or failed, leaves focus on Withdraw.
///
/// ## A host's decisions
///
/// A nomination awaiting approval carries Approve and Reject, and an open
/// one Close vote, each where the viewer's actions hold it (#518):
/// [EventAction.approveGame], [EventAction.rejectGame] and
/// [EventAction.resolveNomination]. A host or co-host holds all three, and a
/// moderator, or a household's owner or admin on its event, Close vote alone.
/// None asks for a row on the roster. Each is left out where the actions
/// don't hold it, since that is the role table and not a state, on an event
/// that takes no writes ([takesDateWrites]: cancelled or archived), and on
/// every other status: a paused nomination can't be settled (#462). They come
/// after Withdraw, and are disabled as it is: offline, saying why once under
/// the row's controls, while a detail read runs, while the screen's own
/// request is out, and while another nominations write is out.
///
/// None of the three can be undone while nothing takes a game out of the
/// lineup (#520), so each asks first ([_decide]): Reject as a destructive
/// action, and Close vote with the row's tally of the votes that count so
/// far, which is what it settles, and the row's line on how the event
/// counts Interested. Then each waits for any running detail read to end,
/// and sends only if the event still takes writes, the viewer's actions
/// still hold it and the nomination still has the status it decides from,
/// as the nominations' state holds it; otherwise nothing is sent, and the
/// footer says so. Each
/// is held from its press through its decision, as Withdraw is. A decision's
/// answer takes the row's place, so the row stays, as decided, and its
/// buttons go: focus goes to the row's lines, as after a withdrawal, and
/// one refused or failed leaves it on the button pressed. How a close of the
/// vote came out, with the server's counts, is the footer's to say: no read
/// carries them.
class EventNominationsSection extends StatelessWidget {
  const EventNominationsSection({
    required this.body,
    required this.rows,
    required this.detail,
    required this.state,
    required this.controller,
    required this.pool,
    required this.poolRead,
    required this.names,
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

  /// The roster's names, by row id.
  final Map<String, String?> names;

  /// Whether the screen's own request is out, or the event is deleted.
  final bool acting;

  /// The screen's clock, which decides whether a deadline has passed and
  /// how a date is named.
  final DateTime now;

  /// Key on the heading's sliver, so it keeps its place as what is under it
  /// changes.
  static const _headingKey = ValueKey<String>('event_nominations.heading');

  /// Key on the header's sliver, so it keeps its state, and its chips their
  /// focus, as what is under it changes.
  static const _headerKey = ValueKey<String>('event_nominations.header');

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final snapshot = detail.detail.snapshot;
    final viewerId = detail.detail.attendance?.id;
    final copies = {for (final game in pool) game.id: game};
    // No vote, no Withdraw and no host decision on an event that takes no
    // writes, cancelled or archived, as no Nominate.
    final takesWrites = takesDateWrites(snapshot.event);
    final mayVote =
        takesWrites &&
        detail.actions.contains(EventAction.voteGame) &&
        viewerId != null;
    final hint = voteHintFor(detail, pool: pool);
    final voting = mayVote
        ? (
            hint: hint == VoteHint.countsWhenOffering && !poolRead
                ? null
                : hint,
            // As the tab's other writes are (#589): not while a detail read
            // runs, or the screen's own request is out or the event is
            // deleted. The nominations' own writes are the control's to hold.
            enabled: !detail.reading && !acting,
            busy: state.busy,
          )
        : null;
    // Withdraw (#517), on the viewer's own live rows, and a host's decisions
    // (#518), on the rows they settle. As a vote is, not while a detail read
    // runs or the screen's own request is out, nor while another
    // nominations write is out.
    final writes = (
      withdraw:
          takesWrites &&
          detail.actions.contains(EventAction.nominateGame) &&
          viewerId != null,
      decisions: {
        if (takesWrites)
          for (final decision in _Decision.values)
            if (detail.actions.contains(decision.action)) decision,
      },
      enabled: !detail.reading && !acting && !state.busy,
      busy: state.busy,
    );
    // A roster read and withheld is an empty list; one not read yet is null,
    // and withholds nothing.
    final rosterShown = !(snapshot.attendees?.isEmpty ?? false);
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
        SliverToBoxAdapter(
          key: _headingKey,
          child: EventGamesTabHeading(title: l10n.eventsNominationsHeading),
        ),
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
          EventNominationsBody.hidden => SliverToBoxAdapter(
            child: _State(
              child: BgeEmptyState(
                icon: Icons.visibility_off_outlined,
                title: l10n.eventsNominationsHiddenTitle,
              ),
            ),
          ),
          EventNominationsBody.loading => SliverToBoxAdapter(
            child: EventSectionSpinner(label: l10n.eventsNominationsLoading),
          ),
          EventNominationsBody.failed => SliverToBoxAdapter(
            child: _State(
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
          ),
          EventNominationsBody.empty => SliverToBoxAdapter(
            child: _State(
              child: BgeEmptyState(
                title: l10n.eventsNominationsEmptyTitle,
                // Pointing to the pool only where the viewer is offered
                // Nominate there.
                body: nominateGate(detail) == NominateGate.open
                    ? l10n.eventsNominationsEmptyBody
                    : null,
              ),
            ),
          ),
          EventNominationsBody.noMatches => SliverToBoxAdapter(
            child: _State(
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
          ),
          EventNominationsBody.rows => BgeKeyedSliverList<EventNomination>(
            items: rows,
            keyOf: (nomination) =>
                EventDetailScreen.nominationRowKey(nomination.id),
            itemBuilder: (context, nomination) => _NominationRow(
              area: controller.nominationArea(nomination.id),
              nomination: nomination,
              viewerId: viewerId,
              names: names,
              copy: copies[nomination.suppliedFromId],
              occurrences: snapshot.occurrences,
              interestedWeight: snapshot.policy?.interestedWeight,
              voting: voting,
              writes: writes,
              rosterShown: rosterShown,
              now: now,
            ),
          ),
        },
        const SliverToBoxAdapter(child: BgeGap.lg()),
      ],
    );
  }
}

/// A heading on the Games tab (#517): the Nominations section's, and the
/// pool's under it, so heading navigation finds each. Announced as a
/// heading. Each list's count is its header's, under its controls.
class EventGamesTabHeading extends StatelessWidget {
  const EventGamesTabHeading({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        header: true,
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      const BgeGap.sm(),
    ],
  );
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
              label: Text(l10n.eventsNominationsFilters),
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

/// A state in the rows' place, spaced from the heading above it and the pool
/// below.
class _State extends StatelessWidget {
  const _State({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceMd),
    child: Center(child: child),
  );
}

/// What the viewer's vote on each open row needs: the line above it, and
/// whether it may be pressed now ([NominationVoteControl.enabled] and
/// [NominationVoteControl.busy]).
typedef _Voting = ({VoteHint? hint, bool enabled, bool busy});

/// What the write buttons on each row need, Withdraw (#517) and a host's
/// decisions (#518): whether the viewer may withdraw their own nominations,
/// the decisions their actions hold, whether these may be pressed now,
/// connection aside ([_RowWriteButton.enabled]), and whether a nominations
/// write is out.
typedef _RowWrites = ({
  bool withdraw,
  Set<_Decision> decisions,
  bool enabled,
  bool busy,
});

/// A host's decision on a nomination (#518), in the order their buttons
/// take on a row: the write it sends, the action in the role table it needs,
/// and the status it settles a nomination from.
enum _Decision {
  approve(
    NominationWrite.approve,
    EventAction.approveGame,
    NominationStatus.awaitingApproval,
    Icons.check_circle_outline,
  ),
  reject(
    NominationWrite.reject,
    EventAction.rejectGame,
    NominationStatus.awaitingApproval,
    Icons.block,
  ),
  resolve(
    NominationWrite.resolve,
    EventAction.resolveNomination,
    NominationStatus.open,
    Icons.lock_outline,
  );

  const _Decision(this.write, this.action, this.from, this.icon);

  final NominationWrite write;
  final EventAction action;

  /// The status a nomination has while this decision is offered on it, and
  /// still has when it is sent.
  final NominationStatus from;

  /// Its button's icon.
  final IconData icon;

  /// Its button's key on the nomination [id].
  Key keyOn(String id) => switch (this) {
    approve => EventDetailScreen.nominationApproveKey(id),
    reject => EventDetailScreen.nominationRejectKey(id),
    resolve => EventDetailScreen.nominationCloseVoteKey(id),
  };

  /// Its button's label.
  String label(EventsLocalizations l10n) => switch (this) {
    approve => l10n.eventsApprove,
    reject => l10n.eventsReject,
    resolve => l10n.eventsCloseVote,
  };

  /// Its button's name to a screen reader, on the nomination of [title].
  String named(EventsLocalizations l10n, String title) => switch (this) {
    approve => l10n.eventsApproveNamed(title),
    reject => l10n.eventsRejectNamed(title),
    resolve => l10n.eventsCloseVoteNamed(title),
  };

  /// Its dialog's title, on the nomination of [title].
  String confirmTitle(EventsLocalizations l10n, String title) => switch (this) {
    approve => l10n.eventsApproveConfirmTitle(title),
    reject => l10n.eventsRejectConfirmTitle(title),
    resolve => l10n.eventsCloseVoteConfirmTitle(title),
  };

  /// Its dialog's confirm button's label.
  String confirmLabel(EventsLocalizations l10n) => switch (this) {
    approve => l10n.eventsApproveConfirm,
    reject => l10n.eventsRejectConfirm,
    resolve => l10n.eventsCloseVoteConfirm,
  };
}

/// One nomination (#517): its picture, then its lines, read as one node, and
/// under both, outside that node and at the row's full width, the viewer's
/// vote while it is open, then *Who voted* once it has a vote, Withdraw on
/// the viewer's own while it is live, and a host's decisions on the status
/// they settle (#518). Its lines take focus when the button whose write just
/// ended goes with it (see "Withdrawing" and "A host's decisions" on
/// [EventNominationsSection]).
class _NominationRow extends StatefulWidget {
  const _NominationRow({
    required this.area,
    required this.nomination,
    required this.viewerId,
    required this.names,
    required this.copy,
    required this.occurrences,
    required this.interestedWeight,
    required this.voting,
    required this.writes,
    required this.rosterShown,
    required this.now,
  });

  /// Holds the whole row, so a row that leaves the rows shown can say it
  /// held focus ([EventGamesTabController.nominationsChanged]), and the row
  /// before or after it can be handed it.
  final FocusNode area;

  final EventNomination nomination;

  /// The viewer's roster row id, where they have one.
  final String? viewerId;
  final Map<String, String?> names;

  /// The pool row the nominated copy comes from, or null where the pool
  /// doesn't hold it.
  final OfferedGame? copy;

  /// The event's dates, one of which a nomination may be for.
  final List<EventOccurrence> occurrences;

  /// How the event counts Interested, or null where its policy isn't known.
  final InterestedWeight? interestedWeight;

  /// What the viewer's vote needs, where they may vote; null where they
  /// may not.
  final _Voting? voting;

  /// What the row's write buttons need.
  final _RowWrites writes;

  /// Whether who voted may name the voters: false where the roster was read
  /// and withheld.
  final bool rosterShown;
  final DateTime now;

  /// Whether the row carries Withdraw: the viewer may withdraw, and it is
  /// their own live nomination.
  bool get offersWithdraw =>
      writes.withdraw &&
      viewerId != null &&
      nomination.nominatedById == viewerId &&
      nomination.status.isLive;

  /// The host's decisions the row carries (#518): those the viewer's actions
  /// hold that settle the status the nomination has.
  List<_Decision> get decisions => [
    for (final decision in _Decision.values)
      if (writes.decisions.contains(decision) &&
          nomination.status == decision.from)
        decision,
  ];

  /// Whether the row carries the button that sends [write]: Withdraw, or one
  /// of [decisions].
  bool offers(NominationWrite write) => write == NominationWrite.withdraw
      ? offersWithdraw
      : decisions.any((decision) => decision.write == write);

  @override
  State<_NominationRow> createState() => _NominationRowState();
}

class _NominationRowState extends State<_NominationRow>
    with BgePointerFocus<_NominationRow> {
  /// The row's lines, as one node: where focus goes once the button whose
  /// write just ended has gone with it. They take focus only then, and are
  /// no stop of their own.
  final FocusNode _lines = FocusNode(
    debugLabel: 'Nomination',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Holds each write button, Withdraw and a host's decisions, by the write
  /// it sends, so the row can tell whether one holds focus.
  final Map<NominationWrite, FocusNode> _areas = {
    for (final write in [
      NominationWrite.withdraw,
      for (final decision in _Decision.values) decision.write,
    ])
      write: FocusNode(
        debugLabel: write.name,
        canRequestFocus: false,
        skipTraversal: true,
      ),
  };

  /// The write a button's press sent, which hasn't ended yet.
  NominationWrite? _sent;

  @override
  void didUpdateWidget(_NominationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Built again with no nominations write out: the write the press sent
    // has ended, and its answer, if any, is in this row.
    final sent = _sent;
    if (sent == null || widget.writes.busy) return;
    _sent = null;
    // Its button stays, as after a refusal, and keeps its own focus.
    if (widget.offers(sent)) return;
    // The button is still built, and goes with this frame, as may the row's
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
  /// decision: [send] asks, and sends it ([_withdraw], [_decide]). Completes
  /// true when the write was sent, which arms the hand-off as it ends.
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
    final names = widget.names;
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final now = widget.now;
    final tally = tallyOf(nomination);
    final deadline = nomination.votingDeadline;
    final supplier = _supplier(l10n);
    final scope = _scope(context, l10n);
    final interested = _interestedLine(l10n, widget.interestedWeight);
    // A fixed line, not a countdown: passing it closes nothing (#517).
    final closes =
        deadline == null || nomination.status != NominationStatus.open
        ? null
        : deadline.isBefore(now)
        ? l10n.eventsNominationDeadlinePassed(
            eventWhenLabel(context, deadline, now: now),
          )
        : l10n.eventsNominationDeadline(
            eventWhenLabel(context, deadline, now: now),
          );
    // The server sets where it goes back to whenever it pauses one; a
    // pause without it says Unknown rather than leave a gap.
    final back = _statusLabel(
      l10n,
      nomination.pausedFrom ?? NominationStatus.unknown,
    );
    final paused = nomination.status != NominationStatus.paused
        ? null
        : switch (supplier) {
            _NobodyNamed() => l10n.eventsNominationPausedUnknown(back),
            _Viewer() => l10n.eventsNominationPausedYours(back),
            _Named(:final name) => l10n.eventsNominationPaused(name, back),
          };
    final viewerId = widget.viewerId;
    final voting = widget.voting;
    final writes = widget.writes;
    final vote = viewerId == null ? null : _viewerVote(nomination, viewerId);
    // Votes are taken while it is open, and only then (#517).
    final control =
        voting == null ||
            viewerId == null ||
            nomination.status != NominationStatus.open
        ? null
        : NominationVoteControl(
            nomination: nomination,
            vote: vote,
            hint: voting.hint,
            enabled: voting.enabled,
            busy: voting.busy,
            onVote: (type) => _vote(context, nomination, type),
            onEditNote: () =>
                _editNote(context, nomination, note: vote?.comment),
          );
    // Where there's no control to show it chosen, the viewer's vote is still
    // theirs to see (#517): on a paused or decided nomination, or once they
    // can't vote.
    final yours = control != null || vote == null
        ? null
        : vote.eligible
        ? l10n.eventsNominationYourVote(voteTypeLabel(l10n, vote.voteType))
        : l10n.eventsNominationYourVoteNotCounting(
            voteTypeLabel(l10n, vote.voteType),
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
    }) => _RowWriteButton(
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
    // Withdraw, then a host's decisions (#518).
    final buttons = [
      if (widget.offersWithdraw)
        button(
          NominationWrite.withdraw,
          key: EventDetailScreen.nominationWithdrawKey(nomination.id),
          label: l10n.eventsWithdraw,
          named: l10n.eventsWithdrawNamed(title),
          icon: Icons.playlist_remove,
          send: () => _withdraw(context, nomination),
        ),
      for (final decision in widget.decisions)
        button(
          decision.write,
          key: decision.keyOn(nomination.id),
          label: decision.label(l10n),
          named: decision.named(l10n, title),
          icon: decision.icon,
          send: () => _decide(
            context,
            nomination,
            decision,
            interestedWeight: widget.interestedWeight,
          ),
        ),
    ];
    final whoVoted = nomination.votes.isEmpty
        ? null
        : _WhoVoted(
            nomination: nomination,
            names: names,
            rosterShown: widget.rosterShown,
            viewerId: viewerId,
          );

    // Read as one node.
    final lines = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(nomination.title, style: theme.textTheme.bodyLarge),
        Text(nomination.platformName, style: quiet),
        Text(_nominatedBy(l10n), style: quiet),
        Text(
          switch (supplier) {
            _NobodyNamed() => l10n.eventsNominationFromUnknown,
            _Viewer() => l10n.eventsNominationFromYours,
            _Named(:final name) => l10n.eventsNominationFrom(name),
          },
          style: quiet,
        ),
        if (scope != null) Text(scope, style: quiet),
        Text(
          _statusLabel(l10n, nomination.status),
          style: theme.textTheme.labelLarge,
        ),
        Text(
          l10n.eventsNominationTally(
            tally.forCount,
            tally.againstCount,
            tally.interestedCount,
          ),
          // The symbol between the counts would be read out.
          semanticsLabel: l10n.eventsNominationTallySpoken(
            tally.forCount,
            tally.againstCount,
            tally.interestedCount,
          ),
          style: quiet,
        ),
        if (interested != null) Text(interested, style: quiet),
        if (yours != null) Text(yours, style: quiet),
        if (closes != null) Text(closes, style: quiet),
        if (paused != null) Text(paused, style: quiet),
      ],
    );

    return Focus(
      focusNode: widget.area,
      includeSemantics: false,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                BgeThumbnail(url: nomination.thumbnail),
                // The ring's inset comes out of the pool's 16: 8 here and 8
                // inside the ring, so the lines sit where the pool's do.
                const BgeGap.sm(axis: Axis.horizontal),
                Expanded(
                  child: MergeSemantics(
                    child: BgeFocusRing(
                      borderRadius: BorderRadius.circular(tokens.radiusSm),
                      suppressed: pointerFocus,
                      builder: (context, onFocusChange) => Focus(
                        focusNode: _lines,
                        onFocusChange: (focused) {
                          onFocusChange(focused);
                          _linesFocusChanged(focused);
                        },
                        // Inset from the ring, which would otherwise run
                        // through the first letter of each line.
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: tokens.spaceSm,
                          ),
                          child: lines,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Under the picture and the lines, at the row's full width: the
            // three choices share it, and beside the picture they would have
            // so little that a chosen Interested shrinks to half size at a
            // phone's width and ordinary text.
            if (control != null) ...[const BgeGap.sm(), control],
            if (whoVoted != null || buttons.isNotEmpty)
              Wrap(
                spacing: tokens.spaceSm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [?whoVoted, ...buttons],
              ),
            // Once for the row's controls: the vote's says it where it is
            // built.
            if (buttons.isNotEmpty &&
                control == null &&
                BgeConnectivityScope.offlineOf(context))
              const BgeOnlineOnlyNote(),
          ],
        ),
      ),
    );
  }

  /// Who nominated it: the viewer, else their name on the roster, else the
  /// username the nomination carries, else "this person", as the pool names
  /// someone the roster doesn't.
  String _nominatedBy(EventsLocalizations l10n) {
    final nomination = widget.nomination;
    final viewerId = widget.viewerId;
    final by = nomination.nominatedById;
    if (viewerId != null && by == viewerId) return l10n.eventsNominatedByYou;
    return l10n.eventsNominatedBy(
      widget.names[by] ??
          personName(username: nomination.nominatedByUsername) ??
          l10n.eventsAttendeeSomeone,
    );
  }

  /// Whose copy it is, from the pool row it was nominated from (#517).
  _Supplier _supplier(EventsLocalizations l10n) {
    final copy = widget.copy;
    final viewerId = widget.viewerId;
    if (copy == null) return const _NobodyNamed();
    if (viewerId != null && copy.attendeeId == viewerId) return const _Viewer();
    return _Named(widget.names[copy.attendeeId] ?? l10n.eventsAttendeeSomeone);
  }

  /// What it is for: the whole event, or the date it names. Null for a date
  /// the event no longer has, rather than name one it doesn't.
  String? _scope(BuildContext context, EventsLocalizations l10n) {
    final id = widget.nomination.occurrenceId;
    if (id == null) return l10n.eventsNominationWholeEvent;
    final date = widget.occurrences.where((each) => each.id == id).firstOrNull;
    if (date == null) return null;
    return l10n.eventsNominationForDate(
      eventDateName(context, date, now: widget.now),
    );
  }
}

/// A write button on a nomination's row: Withdraw on one of the viewer's
/// own live nominations (#517), or a host's Approve, Reject or Close vote
/// (#518). A direct write, so disabled offline through [BgeOnlineOnly], with
/// the connection's reason as its hint. Named for its game to a screen
/// reader ([named]).
///
/// Its press opens a dialog that asks first, which hands focus back to it as
/// it closes, just before the write goes out, and a disabled button can't
/// hold focus (#607). So, as Nominate is, it is held through [HeldPress]
/// from its press until its write is over ([runOver]): enabled, ignoring
/// presses and showing a spinner, wherever it would otherwise be
/// unavailable. It is disabled with no hint while it may not be pressed for
/// a while ([enabled]).
class _RowWriteButton extends StatefulWidget {
  const _RowWriteButton({
    required this.buttonKey,
    required this.label,
    required this.named,
    required this.icon,
    required this.area,
    required this.enabled,
    required this.runOver,
    required this.onPressed,
    required this.onPointerDown,
    super.key,
  });

  /// Key on the button itself.
  final Key buttonKey;

  /// What the button says.
  final String label;

  /// Its name to a screen reader, naming the game.
  final String named;
  final IconData icon;

  /// Holds the button, so its row can tell whether it holds focus.
  final FocusNode area;

  /// Whether it may be pressed now, connection aside: false while a detail
  /// read runs, the screen's own request is out, or a nominations write is
  /// out.
  final bool enabled;

  /// Whether no nominations write is out: once its own write went out, that
  /// is over.
  final bool runOver;

  /// Asks first, and sends the write. Completes true when it was sent, and
  /// false when nothing was.
  final Future<bool> Function() onPressed;

  /// Told the kind of each pointer pressed on it, before the press.
  final void Function(PointerDeviceKind kind) onPointerDown;

  @override
  State<_RowWriteButton> createState() => _RowWriteButtonState();
}

class _RowWriteButtonState extends State<_RowWriteButton>
    with HeldPress<_RowWriteButton> {
  @override
  bool get heldActionOver => widget.runOver;

  @override
  Widget build(BuildContext context) {
    final offline = BgeConnectivityScope.offlineOf(context);
    final available = widget.enabled && !offline;
    // Offline it is disabled, pressed or not: no press made it so (#49).
    final inert = heldInert(available: available, disabled: offline);

    return Focus(
      focusNode: widget.area,
      includeSemantics: false,
      child: Listener(
        onPointerDown: (event) => widget.onPointerDown(event.kind),
        child: BgeOnlineOnly(
          showNote: false,
          child: BgeInertButton(
            inert: inert,
            label: widget.named,
            onPressed: available || inert
                ? () => unawaited(holdPress(widget.onPressed))
                : null,
            builder: (context, focusNode, onPressed) => TextButton.icon(
              key: widget.buttonKey,
              focusNode: focusNode,
              onPressed: onPressed,
              icon: inert ? const _HeldSpinner() : Icon(widget.icon),
              label: Text(widget.label),
            ),
          ),
        ),
      ),
    );
  }
}

/// Withdraws the viewer's own [nomination] once they confirm it, and once
/// any running detail read has ended (#517). Completes true when the
/// withdrawal was sent, and false when nothing was: Keep it, or as below.
///
/// It asks first, as a destructive action: the nomination's votes are lost,
/// and nominating the game again starts from none. Then it goes for the
/// event as the detail shows it then, whose id a reconcile can have moved
/// (#499), and for the nomination as the nominations' state holds it then.
/// Nothing is sent if, by then, the event takes no writes (cancelled or
/// archived), the viewer may no longer nominate, or the nomination is gone,
/// isn't theirs, or is no longer live: the page already shows that, and the
/// footer says the withdrawal was dropped, or a screen reader would hear
/// nothing happen.
Future<bool> _withdraw(
  BuildContext context,
  EventNomination nomination,
) async {
  // Read before the dialog opens: the row under it can rebuild without
  // Withdraw, and take this context with it.
  final l10n = EventsLocalizations.of(context);
  final detail = context.read<EventDetailBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final title = nomination.title;
  final confirmed = await showConfirmDialog(
    context,
    title: l10n.eventsWithdrawConfirmTitle(title),
    body: l10n.eventsWithdrawConfirmBody,
    keepLabel: l10n.eventsWithdrawConfirmKeep,
    confirmLabel: l10n.eventsWithdrawConfirm,
    destructive: true,
    keepKey: EventDetailScreen.withdrawKeepKey,
    confirmKey: EventDetailScreen.withdrawConfirmKey,
  );
  if (!confirmed || nominations.isClosed) return false;

  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;
  final viewer = state.detail.attendance;
  final current = nominations.state.nominations
      .where((shown) => shown.id == nomination.id)
      .firstOrNull;
  if (!takesDateWrites(state.detail.snapshot.event) ||
      !state.actions.contains(EventAction.nominateGame) ||
      viewer == null ||
      current == null ||
      current.nominatedById != viewer.id ||
      !current.status.isLive) {
    nominations.add(
      NominationWriteDropped(NominationWrite.withdraw, title: title),
    );
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  nominations.add(
    NominationWithdrawn(state.detail.snapshot.event.id, current),
  );
  return true;
}

/// Sends a host's [decision] on [nomination] once they confirm it, and once
/// any running detail read has ended (#518). Completes true when it was
/// sent, and false when nothing was: Not yet, or as below.
///
/// None of the three can be undone while nothing takes a game out of the
/// lineup (#520), so each asks first: a rejection as a destructive action,
/// and a close of the vote with [nomination]'s tally of the votes that count
/// so far (#517), which is what it settles, and how the event counts
/// Interested, from [interestedWeight], as the row says it. Then it goes for
/// the event as the detail shows it then, whose id a reconcile can have
/// moved (#499), and for the nomination as the nominations' state holds it
/// then. Nothing is sent if, by then, the event takes no writes (cancelled
/// or archived), the viewer's actions no longer hold the decision, or the
/// nomination is gone or no longer has the status it decides from, or, for a
/// close of the vote, its tally or how the event counts Interested isn't
/// what the dialog showed, as a read while it was open can find (the request
/// carries neither, so the server would settle on what it holds then): the
/// page already shows that, and the footer
/// says the decision was dropped, or a screen reader would hear nothing
/// happen. A host closes the vote on the counts they saw, or presses again.
Future<bool> _decide(
  BuildContext context,
  EventNomination nomination,
  _Decision decision, {
  required InterestedWeight? interestedWeight,
}) async {
  // Read before the dialog opens: the row under it can rebuild without the
  // button, and take this context with it.
  final l10n = EventsLocalizations.of(context);
  final detail = context.read<EventDetailBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final title = nomination.title;
  final tally = tallyOf(nomination);
  final interested = _interestedLine(l10n, interestedWeight);
  final confirmed = await showConfirmDialog(
    context,
    title: decision.confirmTitle(l10n, title),
    body: switch (decision) {
      _Decision.approve => l10n.eventsApproveConfirmBody,
      _Decision.reject => l10n.eventsRejectConfirmBody,
      _Decision.resolve when interested != null =>
        l10n.eventsCloseVoteConfirmBodyInterested(
          tally.forCount,
          tally.againstCount,
          tally.interestedCount,
          interested,
        ),
      _Decision.resolve => l10n.eventsCloseVoteConfirmBody(
        tally.forCount,
        tally.againstCount,
        tally.interestedCount,
      ),
    },
    keepLabel: l10n.eventsHostDecisionKeep,
    confirmLabel: decision.confirmLabel(l10n),
    destructive: decision == _Decision.reject,
    keepKey: EventDetailScreen.hostDecisionKeepKey,
    confirmKey: EventDetailScreen.hostDecisionConfirmKey,
  );
  if (!confirmed || nominations.isClosed) return false;

  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;
  final current = nominations.state.nominations
      .where((shown) => shown.id == nomination.id)
      .firstOrNull;
  if (!takesDateWrites(state.detail.snapshot.event) ||
      !state.actions.contains(decision.action) ||
      current == null ||
      current.status != decision.from ||
      (decision == _Decision.resolve &&
          (tallyOf(current) != tally ||
              state.detail.snapshot.policy?.interestedWeight !=
                  interestedWeight))) {
    nominations.add(NominationWriteDropped(decision.write, title: title));
    return false;
  }
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  final eventId = state.detail.snapshot.event.id;
  nominations.add(switch (decision) {
    _Decision.approve => NominationApproved(eventId, current),
    _Decision.reject => NominationRejected(eventId, current),
    _Decision.resolve => NominationResolved(eventId, current),
  });
  return true;
}

/// How the event counts an Interested vote, as a row says it under its
/// tally and Close vote's dialog says it (#517, #518), or null where the
/// policy isn't known or its weight is one this client can't name.
String? _interestedLine(
  EventsLocalizations l10n,
  InterestedWeight? weight,
) => switch (weight) {
  InterestedWeight.asFor => l10n.eventsNominationInterestedAsFor,
  InterestedWeight.asAgainst => l10n.eventsNominationInterestedAsAgainst,
  InterestedWeight.asAbstain => l10n.eventsNominationInterestedNotCounted,
  InterestedWeight.unknown || null => null,
};

/// A row write button's icon while its write is out: scaled with the label
/// beside it, in the button's icon colour, as the screen's other held
/// buttons'.
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

/// The viewer's vote on [nomination], by their roster row [viewerId], or
/// null before they have voted.
EventNominationVote? _viewerVote(EventNomination nomination, String viewerId) =>
    nomination.votes.where((vote) => vote.attendeeId == viewerId).firstOrNull;

/// Sends the viewer's vote of [type] on [nomination] ([_sendVote]).
/// Completes true when it was sent.
Future<bool> _vote(
  BuildContext context,
  EventNomination nomination,
  VoteType type,
) => _sendVote(
  context.read<EventDetailBloc>(),
  context.read<EventNominationsBloc>(),
  nomination,
  type: type,
);

/// Asks for the note on the viewer's vote on [nomination], with [note], the
/// one it has, in the field, and sends it with that vote ([_sendVote]).
/// Completes true when it was sent: false when the dialog was cancelled, or
/// as [_sendVote] has it.
Future<bool> _editNote(
  BuildContext context,
  EventNomination nomination, {
  String? note,
}) async {
  // Read before the dialog opens: the row under it can rebuild without the
  // control, and take this context with it.
  final detail = context.read<EventDetailBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final written = await showNominationNoteDialog(
    context,
    title: nomination.title,
    note: note,
  );
  if (written == null || nominations.isClosed) return false;
  return _sendVote(detail, nominations, nomination, comment: written);
}

/// Sends the viewer's vote on [nomination] once any running detail read of
/// [detail] has ended (#517): of [type], or, with none, of the type of the
/// vote they have, with [comment] where they wrote a note. Completes true
/// when it was added to [nominations].
///
/// It goes for the event as the detail shows it then, whose id a reconcile
/// can have moved (#499), and for the nomination as [nominations] holds it
/// then. Nothing is sent if, by then, the event takes no writes (cancelled
/// or archived), the viewer may no longer vote, or the nomination is gone or
/// no longer open, or a note has no vote to go with: the page shows that
/// already, and the footer says the vote was dropped, or a screen reader
/// would hear nothing happen. A note the same as the one the vote has sends
/// nothing, and says nothing.
Future<bool> _sendVote(
  EventDetailBloc detail,
  EventNominationsBloc nominations,
  EventNomination nomination, {
  VoteType? type,
  String? comment,
}) async {
  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;

  final viewer = state.detail.attendance;
  final current = nominations.state.nominations
      .where((shown) => shown.id == nomination.id)
      .firstOrNull;
  final own = viewer == null || current == null
      ? null
      : _viewerVote(current, viewer.id);
  final voteType = type ?? own?.voteType;
  if (!takesDateWrites(state.detail.snapshot.event) ||
      !state.actions.contains(EventAction.voteGame) ||
      viewer == null ||
      current == null ||
      current.status != NominationStatus.open ||
      voteType == null ||
      voteType == VoteType.unknown) {
    nominations.add(
      NominationWriteDropped(NominationWrite.vote, title: nomination.title),
    );
    return false;
  }
  // Nothing to send and nothing to say: the note the vote already has.
  if (comment != null && comment == (own?.comment ?? '')) return false;
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  nominations.add(
    NominationVoteCast(
      state.detail.snapshot.event.id,
      current,
      voteType,
      comment: comment,
    ),
  );
  return true;
}

/// *Who voted ({count})* on a row with votes (#517): opens
/// [showNominationVoters], and puts focus back on itself once it has closed,
/// however it was opened, since a screen reader's tap moves no focus. Named
/// for its game to a screen reader.
class _WhoVoted extends StatefulWidget {
  const _WhoVoted({
    required this.nomination,
    required this.names,
    required this.rosterShown,
    required this.viewerId,
  });

  final EventNomination nomination;
  final Map<String, String?> names;
  final bool rosterShown;
  final String? viewerId;

  @override
  State<_WhoVoted> createState() => _WhoVotedState();
}

class _WhoVotedState extends State<_WhoVoted> {
  final FocusNode _focus = FocusNode(debugLabel: 'Who voted');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await showNominationVoters(
      context,
      widget.nomination,
      names: widget.names,
      rosterShown: widget.rosterShown,
      viewerId: widget.viewerId,
    );
    if (mounted && _focus.context != null) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final nomination = widget.nomination;
    // Every vote, those that don't count included: the list marks them.
    final count = nomination.votes.length;

    return TextButton.icon(
      key: EventDetailScreen.nominationVotersKey(nomination.id),
      focusNode: _focus,
      onPressed: () => unawaited(_open()),
      icon: const Icon(Icons.how_to_vote_outlined),
      label: Text(
        l10n.eventsVotersOpen(count),
        semanticsLabel: l10n.eventsVotersOpenNamed(count, nomination.title),
      ),
    );
  }
}

/// Who brings a nominated copy: someone named, the viewer, or nobody the
/// pool can name.
sealed class _Supplier {
  const _Supplier();
}

/// Someone other than the viewer.
final class _Named extends _Supplier {
  const _Named(this.name);

  /// Their name on the roster, or "this person".
  final String name;
}

/// The viewer.
final class _Viewer extends _Supplier {
  const _Viewer();
}

/// Nobody the pool can name: it no longer holds the row.
final class _NobodyNamed extends _Supplier {
  const _NobodyNamed();
}

/// Where a nomination stands, as its row says it. Unlike the event's own
/// labels, an unknown status has one: a paused row names the status it goes
/// back to, and needs a word for one this client can't read.
String _statusLabel(EventsLocalizations l10n, NominationStatus status) =>
    switch (status) {
      NominationStatus.open => l10n.eventsNominationStatusVoting,
      NominationStatus.awaitingApproval =>
        l10n.eventsNominationStatusAwaitingApproval,
      NominationStatus.approved => l10n.eventsNominationStatusApproved,
      NominationStatus.passed => l10n.eventsNominationStatusPassed,
      NominationStatus.failed => l10n.eventsNominationStatusFailed,
      NominationStatus.quorumNotMet => l10n.eventsNominationStatusQuorumNotMet,
      NominationStatus.rejected => l10n.eventsNominationStatusRejected,
      NominationStatus.withdrawn => l10n.eventsNominationStatusWithdrawn,
      NominationStatus.paused => l10n.eventsNominationStatusPaused,
      NominationStatus.unknown => l10n.eventsNominationStatusUnknown,
    };
