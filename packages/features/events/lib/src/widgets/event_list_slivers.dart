import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_overview_bloc.dart';
import 'package:events/src/bloc/event_overview_event.dart';
import 'package:events/src/bloc/event_overview_state.dart';
import 'package:events/src/overview/event_groups.dart';
import 'package:events/src/screens/event_overview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the overview and every group's page show around their rows (#497):
/// the couldn't-refresh banner over whatever the cache holds, the
/// first-fill spinner, and the failed read. [ready] builds the rows from
/// the cache's grouped answer.
///
/// Reads an [EventOverviewBloc] from context. The surfaces are the
/// collection list's, keyed with [EventOverviewScreen]'s keys on either page.
class EventListStatesSliver extends StatelessWidget {
  const EventListStatesSliver({required this.ready, super.key});

  final Widget Function(BuildContext context, EventGroups groups) ready;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final bloc = context.read<EventOverviewBloc>();
    void retry() => bloc.add(const EventOverviewRetryRequested());

    return BlocBuilder<EventOverviewBloc, EventOverviewState>(
      builder: (context, state) => SliverMainAxisGroup(
        slivers: [
          if (state
              case EventOverviewReady(:final refreshFailed, :final refreshing)
              when refreshFailed || refreshing)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceMd),
                child: BgeRefreshBanner(
                  key: EventOverviewScreen.refreshBannerKey,
                  retryKey: EventOverviewScreen.refreshRetryKey,
                  failedMessage: l10n.eventsRefreshFailed,
                  inProgressLabel: l10n.eventsRefreshInProgress,
                  retryLabel: l10n.eventsRefreshRetry,
                  refreshing: refreshing,
                  onRetry: bloc.canRetry ? retry : null,
                ),
              ),
            ),
          switch (state) {
            EventOverviewLoading() => BgeStateSliver(
              child: BgeLoadingState(
                key: EventOverviewScreen.loadingKey,
                label: l10n.eventsLoading,
              ),
            ),
            EventOverviewError(:final retrying) => BgeStateSliver(
              child: bloc.canRetry
                  // #49's error-with-retry. The pass writes to the tables the
                  // failed read watches, which is what makes drift run it
                  // again.
                  ? BgeErrorState(
                      key: EventOverviewScreen.errorKey,
                      icon: Icons.error_outline,
                      title: l10n.eventsError,
                      body: l10n.eventsErrorBody,
                      retryLabel: l10n.eventsRefreshRetry,
                      retryProgressLabel: l10n.eventsRefreshInProgress,
                      retrying: retrying,
                      onRetry: retry,
                    )
                  // No pass to run, so no button that would do nothing.
                  : BgeInlineBanner(
                      key: EventOverviewScreen.errorKey,
                      tone: BgeBannerTone.error,
                      message: l10n.eventsError,
                    ),
            ),
            EventOverviewReady(:final groups) => ready(context, groups),
          },
        ],
      ),
    );
  }
}

/// A group's name: its heading on the overview, and its page's title.
String eventGroupName(EventsLocalizations l10n, EventGroup group) =>
    switch (group) {
      EventGroup.upcoming => l10n.eventsGroupUpcoming,
      EventGroup.planning => l10n.eventsGroupPlanning,
      EventGroup.past => l10n.eventsGroupPast,
      EventGroup.archived => l10n.eventsGroupArchived,
    };
