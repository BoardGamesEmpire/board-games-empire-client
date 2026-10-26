import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/event_detail_bloc.dart';
import '../bloc/event_detail_event.dart';
import '../bloc/event_detail_state.dart';
import '../widgets/event_detail_sections.dart';
import '../widgets/event_refresh_banner.dart';

/// One event (#498): its header, its dates, who's coming and its games, read
/// reactively from the local cache and from the server once per open.
///
/// The household detail's shape: the caller resolves the repository, the
/// optional server and streams and the callbacks, and the screen owns its
/// bloc ([EventDetailBloc], whose class doc has the state table). Loading,
/// not found and error are short centred pages. Ready is one scrolling page,
/// with the couldn't-refresh banner over the cached event where the last
/// read failed.
///
/// ## What it doesn't show yet
///
/// No action buttons: the bloc works out what the viewer may do, and each
/// action's own issue (#500–#518) adds its button. The games section says
/// they will show there, until #519 has something to show.
///
/// ## Not found is an answer
///
/// The server answers 404 for an event that was deleted and for one this
/// user may no longer read, and does not say which, so neither does the
/// screen.
class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({
    required this.eventId,
    required this.repository,
    this.remote,
    this.confirmSession,
    this.households,
    this.householdRole,
    this.onBack,
    this.now,
    super.key,
  });

  /// Key on the first-read spinner.
  static const Key loadingKey = Key('event_detail.loading');

  /// Key on the not-found surface.
  static const Key notFoundKey = Key('event_detail.not_found');

  /// Key on the not-found surface's way back to the events.
  static const Key notFoundBackKey = Key('event_detail.not_found_back');

  /// Key on the failed-read surface.
  static const Key errorKey = Key('event_detail.error');

  /// Key on the failed-read surface's retry button.
  static const Key errorRetryKey = Key('event_detail.error_retry');

  /// Key on the couldn't-refresh banner.
  static const Key refreshBannerKey = Key('event_detail.refresh_banner');

  /// Key on the banner's retry button.
  static const Key refreshRetryKey = Key('event_detail.refresh_retry');

  /// Key on the dates section.
  static const Key datesKey = Key('event_detail.dates');

  /// Key on the who's-coming section.
  static const Key attendeesKey = Key('event_detail.attendees');

  /// Key on the games section.
  static const Key gamesKey = Key('event_detail.games');

  /// Key on the viewer's role line.
  static const Key roleKey = Key('event_detail.role');

  /// The event to show.
  final String eventId;

  /// The user-session event repository, which the screen's read writes to.
  final EventRepository repository;

  /// The per-server event client, for the read every open makes and the
  /// retry. Null reads nothing and offers no retry: the screen shows the
  /// cache alone.
  final EventRemoteDataSource? remote;

  /// Whether the session is still the user [repository] belongs to, asked
  /// before the read goes out and before its answer is written (#432). Null,
  /// as on native, is always yes.
  final Future<bool> Function()? confirmSession;

  /// The cached households, for the header's household name. Null names
  /// none, and is never waited on.
  final Stream<List<Household>>? households;

  /// The viewer's role in a household, for what they may do to its events
  /// without attending. Null gives household roles no say.
  final Future<HouseholdRole?> Function(String householdId)? householdRole;

  /// Returns to the events from the not-found state, as that surface's
  /// primary action, with this screen's context: the feature package doesn't
  /// know the route table. Null offers no such button, and the app bar's
  /// back button still leaves.
  final void Function(BuildContext context)? onBack;

  /// The clock that decides whether a date is this year's. Defaults to the
  /// device's.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<EventDetailBloc>(
      // go_router keeps this page when only the id changes; the key makes a
      // new id a new bloc rather than the old event under it, as the
      // household detail's does (#466).
      key: ValueKey<String>(eventId),
      create: (_) => EventDetailBloc(
        eventId: eventId,
        repository: repository,
        remote: remote,
        confirmSession: confirmSession,
        households: households,
        householdRole: householdRole,
      ),
      child: _EventDetailView(onBack: onBack, now: now ?? DateTime.now),
    );
  }
}

class _EventDetailView extends StatelessWidget {
  const _EventDetailView({required this.now, this.onBack});

  final DateTime Function() now;
  final void Function(BuildContext context)? onBack;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<EventDetailBloc, EventDetailState>(
      builder: (context, state) => switch (state) {
        EventDetailLoading() => const _LoadingPage(),
        EventDetailNotFound() => _NotFoundPage(onBack: onBack),
        EventDetailError(:final refreshing, :final canRetry) => _ErrorPage(
          refreshing: refreshing,
          canRetry: canRetry,
        ),
        EventDetailReady() => _ReadyPage(state: state, now: now),
      },
    );
  }
}

/// The event itself.
class _ReadyPage extends StatelessWidget {
  const _ReadyPage({required this.state, required this.now});

  final EventDetailReady state;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final snapshot = state.detail.snapshot;
    final event = snapshot.event;

    return BgePage(
      // The section name, not the event's: the title is the page's heading
      // below, where a long one wraps rather than being cut short.
      title: Text(l10n.eventsTitle),
      width: BgePageWidth.pane,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.refreshFailed || state.refreshing) ...[
            EventRefreshBanner(
              key: EventDetailScreen.refreshBannerKey,
              retryKey: EventDetailScreen.refreshRetryKey,
              failedMessage: l10n.eventsDetailRefreshFailed,
              refreshing: state.refreshing,
              onRetry: state.canRetry ? () => _retry(context) : null,
            ),
            const BgeGap.lg(),
          ],
          EventDetailHeader(
            event: event,
            householdName: state.householdName,
            role: state.detail.attendance?.role,
          ),
          const BgeGap.xl(),
          EventDatesSection(
            occurrences: snapshot.occurrences,
            schedulingMode: event.schedulingMode,
            now: now,
          ),
          const BgeGap.lg(),
          EventAttendeesSection(attendees: snapshot.attendees),
          const BgeGap.lg(),
          const EventGamesSection(),
        ],
      ),
    );
  }
}

/// Nothing cached to show and nothing that will answer: the overview's two
/// failed-read surfaces, for one event.
///
/// Where the bloc would read again ([EventDetailError.canRetry]), #102's
/// error-with-retry. The retry stays in place while it runs, disabled and
/// saying so, rather than giving way to a spinner: a press that left the
/// failure up would otherwise look like one that did nothing. Where it
/// wouldn't, with no server or once the cache has ended, the failure alone,
/// with no button that would do nothing.
class _ErrorPage extends StatelessWidget {
  const _ErrorPage({required this.refreshing, required this.canRetry});

  final bool refreshing;
  final bool canRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return _MessagePage(
      child: canRetry
          ? BgeErrorState(
              key: EventDetailScreen.errorKey,
              retryKey: EventDetailScreen.errorRetryKey,
              icon: Icons.error_outline,
              title: l10n.eventsDetailError,
              body: l10n.eventsDetailErrorBody,
              retryLabel: l10n.eventsRefreshRetry,
              retryProgressLabel: l10n.eventsRefreshInProgress,
              retrying: refreshing,
              onRetry: () => _retry(context),
            )
          : BgeInlineBanner(
              key: EventDetailScreen.errorKey,
              tone: BgeBannerTone.error,
              message: l10n.eventsDetailError,
            ),
    );
  }
}

/// No event the user may read at this id; see [EventDetailScreen].
class _NotFoundPage extends StatelessWidget {
  const _NotFoundPage({this.onBack});

  final void Function(BuildContext context)? onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final back = onBack;

    return _MessagePage(
      child: Column(
        key: EventDetailScreen.notFoundKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.eventsDetailNotFoundTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          const BgeGap.sm(),
          Text(
            l10n.eventsDetailNotFoundBody,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          // The app bar's back button does the same. This one is here
          // because leaving is the likely intent on this surface.
          if (back != null) ...[
            const BgeGap.lg(),
            FilledButton.icon(
              key: EventDetailScreen.notFoundBackKey,
              onPressed: () => back(context),
              icon: const Icon(Icons.event_outlined),
              label: Text(l10n.eventsDetailNotFoundAction),
            ),
          ],
        ],
      ),
    );
  }
}

class _LoadingPage extends StatelessWidget {
  const _LoadingPage();

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return _MessagePage(
      child: Center(
        key: EventDetailScreen.loadingKey,
        child: Semantics(
          liveRegion: true,
          label: l10n.eventsDetailLoading,
          // The label carries the announcement; the spinner has nothing to
          // say to a screen reader.
          child: const ExcludeSemantics(child: CircularProgressIndicator()),
        ),
      ),
    );
  }
}

/// A short message centred on an otherwise empty page.
class _MessagePage extends StatelessWidget {
  const _MessagePage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => BgePage(
    title: Text(EventsLocalizations.of(context).eventsTitle),
    width: BgePageWidth.pane,
    centerVertically: true,
    child: child,
  );
}

/// The only event the screen sends (#498): read the event again.
void _retry(BuildContext context) =>
    context.read<EventDetailBloc>().add(const EventDetailRetryRequested());
