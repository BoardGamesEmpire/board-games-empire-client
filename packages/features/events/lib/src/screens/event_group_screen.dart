import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/event_overview_bloc.dart';
import '../bloc/event_overview_state.dart';
import '../overview/event_groups.dart';
import '../sync/event_hydration_status.dart';
import '../widgets/event_list_slivers.dart';
import '../widgets/event_row.dart';
import 'event_overview_screen.dart';

/// Every event in one of the overview's groups (#497), in the group's
/// order, in one lazily built list over the cache.
///
/// Opened from a group's *See all* on [EventOverviewScreen], with a bloc of
/// its own over the same cache and the overview's banner, spinner and
/// failed read. The cache already holds
/// every page of the user's list, and the server pages it by creation date
/// rather than by event date, so a lazy list that builds only the rows on
/// screen does all paging would, without asking the server for anything.
///
/// It has no `onEnter`: it is pushed above the overview, which asked for a
/// stale re-hydrate on its own entry.
///
/// A group can empty while its page is open, as when its last upcoming event
/// ends. The page stays, and says so.
class EventGroupScreen extends StatelessWidget {
  const EventGroupScreen({
    required this.group,
    required this.repository,
    this.households,
    this.hydration,
    this.onOpen,
    this.onCreate,
    this.onRetry,
    this.now,
    super.key,
  });

  /// Key on the group's empty state.
  static const Key emptyKey = Key('events.group_empty');

  /// Key on the create button.
  static const Key createKey = Key('events.group_create');

  /// The group this page lists.
  final EventGroup group;

  /// See [EventOverviewScreen.repository].
  final EventRepository repository;

  /// See [EventOverviewScreen.households].
  final Stream<List<Household>>? households;

  /// See [EventOverviewScreen.hydration].
  final Stream<EventHydration>? hydration;

  /// See [EventOverviewScreen.onOpen].
  final void Function(BuildContext context, String eventId)? onOpen;

  /// Starts creating an event (#499), or null for no create button. See
  /// [EventOverviewScreen.onCreate].
  final void Function(BuildContext context)? onCreate;

  /// See [EventOverviewScreen.onRetry].
  final Future<void> Function()? onRetry;

  /// See [EventOverviewScreen.now].
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<EventOverviewBloc>(
      create: (_) => EventOverviewBloc(
        repository: repository,
        households: households,
        hydration: hydration,
        onRetry: onRetry,
        now: now,
      ),
      child: _EventGroupPage(
        group: group,
        onOpen: onOpen,
        onCreate: onCreate,
        now: now,
      ),
    );
  }
}

class _EventGroupPage extends StatelessWidget {
  const _EventGroupPage({
    required this.group,
    this.onOpen,
    this.onCreate,
    this.now,
  });

  final EventGroup group;
  final void Function(BuildContext context, String eventId)? onOpen;
  final void Function(BuildContext context)? onCreate;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final clock = now ?? DateTime.now;
    final create = onCreate;
    final tokens = BgeTokens.of(context);
    // The row count, for "item 3 of 9" (#210).
    final rowCount = context.select<EventOverviewBloc, int?>(
      (bloc) => switch (bloc.state) {
        EventOverviewReady(:final groups) when groups.of(group).isNotEmpty =>
          groups.of(group).length,
        _ => null,
      },
    );

    return BgePage.slivers(
      title: Text(eventGroupName(l10n, group)),
      width: BgePageWidth.pane,
      semanticChildCount: rowCount,
      // The overview's button, so a group that has emptied still has a way
      // to make the next event.
      floatingActionButton: create == null
          ? null
          : FloatingActionButton.extended(
              key: EventGroupScreen.createKey,
              onPressed: () => create(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.eventsCreate),
            ),
      slivers: [
        EventListStatesSliver(
          ready: (context, groups) {
            final rows = groups.of(group);
            if (rows.isEmpty) {
              return EventMessageSliver(
                child: Text(
                  l10n.eventsGroupEmpty,
                  key: EventGroupScreen.emptyKey,
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              );
            }
            return SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) => EventRowTile(
                key: EventOverviewScreen.rowKey(rows[index].event.id),
                row: rows[index],
                now: clock,
                onOpen: onOpen,
              ),
            );
          },
        ),
        // The create button floats over the end of the list; room below the
        // rows lets the last one scroll clear of it.
        if (create != null && rowCount != null)
          SliverToBoxAdapter(
            child: SizedBox(height: tokens.spaceXxl + tokens.spaceMd),
          ),
      ],
    );
  }
}
