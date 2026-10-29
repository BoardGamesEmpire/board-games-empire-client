import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/event_overview_bloc.dart';
import '../bloc/event_overview_state.dart';
import '../overview/event_groups.dart';
import '../widgets/event_list_slivers.dart';
import '../widgets/event_row.dart';

/// The events overview (#497): the user's events as Upcoming, Planning and
/// Past, each showing its first [groupCap], read reactively from the local
/// cache.
///
/// The collection list's shape (`GameCollectionListScreen`): the caller
/// resolves the repository, the optional streams and the callbacks, and the
/// screen owns its bloc. Loading, empty, rows and error come from a sealed
/// state; a failed refresh is a banner over whatever the cache holds, with a
/// retry where the composition can run one.
///
/// ## Capped groups, each with a page of its own
///
/// Three groups of [groupCap] keep the overview to a screen on a phone. A
/// group holding more names how many in a *See all* button beside its
/// heading, which opens the group's page ([onOpenGroup]). The button, not
/// the group, is what opens it: once rows open their events, a tappable
/// group would nest one tap target inside another. A group of [groupCap] or fewer
/// has no button, because every event in it is already shown, and a group
/// with none is left off.
///
/// ## The page is thin
///
/// The overview itself is [EventOverviewSliver], and this screen is a
/// `BgePage` around it plus the bloc it reads, as the collection list is
/// (#44), so a host can put the sliver in its own scroll view without this
/// page's app bar.
///
/// ## Hooks a composition may leave out
///
/// Without [onOpen] a row is inert content, not a focus stop: a tap that
/// leads nowhere is worse than no tap (#269). The shell passes it where it
/// has a detail route (#498). Without [onCreate] there is no create button,
/// neither the one beside the list nor the one the empty state offers
/// (#499).
class EventOverviewScreen extends StatelessWidget {
  const EventOverviewScreen({
    required this.repository,
    this.households,
    this.hydration,
    this.onOpen,
    this.onOpenGroup,
    this.onCreate,
    this.onRetry,
    this.onEnter,
    this.now,
    super.key,
  });

  /// How many events each group shows on the overview.
  static const int groupCap = 5;

  /// Key on the first-fill spinner, here and on a group's page.
  static const Key loadingKey = Key('events.loading');

  /// Key on the empty state.
  static const Key emptyKey = Key('events.empty');

  /// Key on the empty state's create button.
  static const Key emptyCreateKey = Key('events.empty_create');

  /// Key on the failed-read surface, here and on a group's page.
  static const Key errorKey = Key('events.error');

  /// Key on the couldn't-refresh banner, here and on a group's page.
  static const Key refreshBannerKey = Key('events.refresh_banner');

  /// Key on the banner's retry button.
  static const Key refreshRetryKey = Key('events.refresh_retry');

  /// Key on the floating create button, beside the list. The empty state's
  /// own is [emptyCreateKey].
  static const Key createKey = Key('events.create');

  /// Key on one group: `events.group_<name>`.
  static Key groupKey(EventGroup group) => Key('events.group_${group.name}');

  /// Key on one group's see-all button: `events.see_all_<name>`.
  static Key seeAllKey(EventGroup group) => Key('events.see_all_${group.name}');

  /// Per-row key, here and on a group's page: `events.row_<eventId>`.
  ///
  /// Held by the wrapper [BgeKeyedSliverList] puts around each row, not by
  /// the row, so a finder by it reaches the whole row (#549).
  static Key rowKey(String eventId) => Key('events.row_$eventId');

  /// The user-session event repository. Read-only here.
  final EventRepository repository;

  /// The cached households, for each row's household name. Null shows no
  /// names, and is never waited on.
  final Stream<List<Household>>? households;

  /// What the hydrate is doing, when this composition runs one. Null reads
  /// as settled rather than as loading forever.
  final Stream<Hydration>? hydration;

  /// Opens one event, or null where there is nowhere to open it.
  final void Function(BuildContext context, String eventId)? onOpen;

  /// Opens one group's page, or null where there is none to open.
  final void Function(BuildContext context, EventGroup group)? onOpenGroup;

  /// Starts creating an event (#499), or null where this composition has no
  /// create form to open. Null draws no create button, here or in the empty
  /// state.
  final void Function(BuildContext context)? onCreate;

  /// Runs one more hydrate pass, or null where this composition has none.
  /// Absent, the banner still reports a failed refresh and offers nothing to
  /// press.
  final Future<void> Function()? onRetry;

  /// Asks for a stale re-hydrate when this screen is entered. Fire-and-forget:
  /// the caller owns the error handling, and what it starts is not narrated.
  final VoidCallback? onEnter;

  /// The clock the events are grouped against. Defaults to the device's.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<EventOverviewBloc>(
      create: (_) {
        final bloc = EventOverviewBloc(
          repository: repository,
          households: households,
          hydration: hydration,
          onRetry: onRetry,
          now: now,
        );
        // Here, not in the route builder: `create` runs once per entry,
        // whereas go_router re-runs a route's builder on every router
        // rebuild (#300). After the bloc, so its subscription is in place
        // before the pass can report anything.
        onEnter?.call();
        return bloc;
      },
      child: _EventOverviewPage(
        onOpen: onOpen,
        onOpenGroup: onOpenGroup,
        onCreate: onCreate,
        now: now,
      ),
    );
  }
}

class _EventOverviewPage extends StatelessWidget {
  const _EventOverviewPage({
    this.onOpen,
    this.onOpenGroup,
    this.onCreate,
    this.now,
  });

  final void Function(BuildContext context, String eventId)? onOpen;
  final void Function(BuildContext context, EventGroup group)? onOpenGroup;
  final void Function(BuildContext context)? onCreate;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final create = onCreate;
    // The rows shown, for "item 3 of 9". The page owns the scroll view, so
    // the page passes it (#210).
    final rowCount = context.select<EventOverviewBloc, int?>(
      (bloc) => switch (bloc.state) {
        EventOverviewReady(:final groups) when !groups.isEmpty =>
          EventOverviewSliver.shownRowCount(groups),
        _ => null,
      },
    );

    return BgePage.slivers(
      title: Text(l10n.eventsTitle),
      // A list surface, so the wider measure.
      width: BgePageWidth.pane,
      semanticChildCount: rowCount,
      floatingActionButton: create == null
          ? null
          : FloatingActionButton.extended(
              key: EventOverviewScreen.createKey,
              onPressed: () => create(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.eventsCreate),
            ),
      slivers: [
        EventOverviewSliver(
          onOpen: onOpen,
          onOpenGroup: onOpenGroup,
          onCreate: onCreate,
          now: now,
        ),
      ],
    );
  }
}

/// The overview's content, as one sliver (#497).
///
/// Reads an [EventOverviewBloc] from context. [EventOverviewScreen] provides
/// one inside a page; another host provides its own and puts this in its
/// own scroll view. The host owns that scroll view, so it
/// also owns its `semanticChildCount`, which [shownRowCount] gives it.
class EventOverviewSliver extends StatelessWidget {
  const EventOverviewSliver({
    this.onOpen,
    this.onOpenGroup,
    this.onCreate,
    this.now,
    super.key,
  });

  /// See [EventOverviewScreen.onOpen].
  final void Function(BuildContext context, String eventId)? onOpen;

  /// See [EventOverviewScreen.onOpenGroup].
  final void Function(BuildContext context, EventGroup group)? onOpenGroup;

  /// Starts creating an event from the empty state's button, or null for no
  /// button there (#499). The button beside the list is the page's, so a
  /// host draws its own.
  final void Function(BuildContext context)? onCreate;

  /// See [EventOverviewScreen.now].
  final DateTime Function()? now;

  /// How many rows the overview shows for [groups]: each group's, up to
  /// [EventOverviewScreen.groupCap].
  static int shownRowCount(EventGroups groups) => EventGroup.values.fold(
    0,
    (sum, group) =>
        sum + math.min(groups.of(group).length, EventOverviewScreen.groupCap),
  );

  @override
  Widget build(BuildContext context) {
    final clock = now ?? DateTime.now;

    return EventListStatesSliver(
      ready: (context, groups) {
        if (groups.isEmpty) return _EmptySliver(onCreate: onCreate);

        // Numbered across the groups, so a screen reader's "item 7 of 12"
        // counts every row on the overview, not each group's afresh.
        final slivers = <Widget>[];
        var shownBefore = 0;
        for (final group in EventGroup.values) {
          final rows = groups.of(group);
          if (rows.isEmpty) continue;
          slivers.add(
            _GroupSliver(
              key: EventOverviewScreen.groupKey(group),
              group: group,
              rows: rows,
              semanticIndexOffset: shownBefore,
              now: clock,
              onOpen: onOpen,
              onOpenGroup: onOpenGroup,
            ),
          );
          shownBefore += math.min(rows.length, EventOverviewScreen.groupCap);
        }
        return SliverMainAxisGroup(slivers: slivers);
      },
    );
  }
}

/// One group on the overview: its heading, then its first
/// [EventOverviewScreen.groupCap] rows.
class _GroupSliver extends StatelessWidget {
  const _GroupSliver({
    required this.group,
    required this.rows,
    required this.semanticIndexOffset,
    required this.now,
    this.onOpen,
    this.onOpenGroup,
    super.key,
  });

  final EventGroup group;
  final List<EventRow> rows;

  /// How many rows the groups above this one show.
  final int semanticIndexOffset;
  final DateTime Function() now;
  final void Function(BuildContext context, String eventId)? onOpen;
  final void Function(BuildContext context, EventGroup group)? onOpenGroup;

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _GroupHeader(
            group: group,
            count: rows.length,
            onOpenGroup: onOpenGroup,
          ),
        ),
        BgeKeyedSliverList<EventRow>(
          items: rows.take(EventOverviewScreen.groupCap).toList(),
          keyOf: (row) => EventOverviewScreen.rowKey(row.event.id),
          semanticIndexOffset: semanticIndexOffset,
          itemBuilder: (context, row) =>
              EventRowTile(row: row, now: now, onOpen: onOpen),
        ),
      ],
    );
  }
}

/// A group's heading, with a button to the group's page when it holds more
/// than the overview shows.
///
/// Side by side where both fit, and stacked where they don't, as at 200%
/// text on a narrow window.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.count,
    this.onOpenGroup,
  });

  final EventGroup group;
  final int count;
  final void Function(BuildContext context, EventGroup group)? onOpenGroup;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final name = eventGroupName(l10n, group);
    final open = onOpenGroup;
    final seeAll = open != null && count > EventOverviewScreen.groupCap;

    return Padding(
      // In line with the rows' titles, which the tiles inset.
      padding: EdgeInsetsDirectional.only(
        start: tokens.spaceMd,
        top: tokens.spaceMd,
      ),
      child: OverflowBar(
        alignment: seeAll ? MainAxisAlignment.spaceBetween : null,
        children: [
          Semantics(
            header: true,
            child: Text(name, style: Theme.of(context).textTheme.titleSmall),
          ),
          if (seeAll)
            TextButton(
              key: EventOverviewScreen.seeAllKey(group),
              onPressed: () => open(context, group),
              child: Text(
                l10n.eventsGroupSeeAll(count),
                // The number alone doesn't say what it counts, nor which
                // group the button opens.
                semanticsLabel: l10n.eventsGroupSeeAllSpoken(name, count),
              ),
            ),
        ],
      ),
    );
  }
}

/// No events at all, with a New event button where [onCreate] is given
/// (#499). The page's own button sits in a corner, and the empty state is
/// where the user is looking.
class _EmptySliver extends StatelessWidget {
  const _EmptySliver({this.onCreate});

  final void Function(BuildContext context)? onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final create = onCreate;

    return EventMessageSliver(
      child: Column(
        key: EventOverviewScreen.emptyKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.eventsEmptyTitle,
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const BgeGap.sm(),
          Text(
            l10n.eventsEmptyBody,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (create != null) ...[
            const BgeGap.lg(),
            FilledButton.icon(
              key: EventOverviewScreen.emptyCreateKey,
              onPressed: () => create(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.eventsCreate),
            ),
          ],
        ],
      ),
    );
  }
}
