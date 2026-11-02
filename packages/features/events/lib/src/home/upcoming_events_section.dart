import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/event_overview_bloc.dart';
import '../bloc/event_overview_event.dart';
import '../bloc/event_overview_state.dart';
import '../overview/event_groups.dart';
import '../widgets/event_loading_indicator.dart';
import '../widgets/event_refresh_banner.dart';
import '../widgets/event_row.dart';
import 'upcoming_fallback_cubit.dart';

/// The home page's upcoming events (#613): the user's next few events, or, with
/// none of their own, what's coming up that they could see.
///
/// ## Two sources, and the cache decides between them
///
/// The user's own events come from an [EventOverviewBloc], so grouping, the
/// clock and the first hydrate behave as they do on the overview. An
/// [UpcomingFallbackCubit] owns the fallback, and is told to read only once that
/// bloc is ready with nothing upcoming and no first fill running. So the first
/// sync can't flash other people's events ahead of the user's own, even with
/// planning or past rows already cached, and the user's own event arriving
/// replaces the fallback at once.
///
/// A failed pass holds the fallback back, and the section shows its empty text
/// until one lands. The pass may not have reached the user's events, so saying
/// they have none upcoming could be false, and other people's rows under this
/// heading with no note would read as the user's own.
///
/// The fallback's rows stay off the events screen, so the link can't promise to
/// show them all. It reads "See all" over the user's own rows and "Your events"
/// everywhere else, and it's always there because the events screen also holds
/// planning and past events. It stays one control as its words change, so focus
/// stays on it.
///
/// ## Home starts no hydrate
///
/// Unlike the overview's, this bloc is given no entry trigger: activating the
/// session already runs a pass, and home is where the session lands. A failed
/// pass draws no banner here either, and the rows stay up. A failed read of the
/// cache itself is the one error this section shows, with a retry.
class UpcomingEventsSection extends StatelessWidget {
  const UpcomingEventsSection({
    required this.repository,
    required this.onOpenEvents,
    this.households,
    this.hydration,
    this.onRetry,
    this.remote,
    this.connectivity,
    this.onOpen,
    this.now,
    super.key,
  });

  /// The most rows the section shows, in either state.
  static const int rowCap = UpcomingFallbackCubit.rowCap;

  /// Key on the section's heading.
  static const Key headingKey = Key('events.home_heading');

  /// Key on the link to the events screen.
  static const Key linkKey = Key('events.home_link');

  /// Key on the spinner.
  static const Key loadingKey = Key('events.home_loading');

  /// Key on the text saying nothing's coming up.
  static const Key emptyKey = Key('events.home_empty');

  /// Key on the failed cache read's banner.
  static const Key errorKey = Key('events.home_error');

  /// Key on the banner's retry button.
  static const Key retryKey = Key('events.home_retry');

  /// Key on the line above the fallback's rows.
  static const Key fallbackNoteKey = Key('events.home_fallback_note');

  /// Per-row key: `events.home_row_<eventId>`.
  static Key rowKey(String eventId) => Key('events.home_row_$eventId');

  /// The user-session event repository. Read-only here: nothing in this section
  /// writes the cache.
  final EventRepository repository;

  /// Opens the events screen.
  final void Function(BuildContext context) onOpenEvents;

  /// Makes a stream of the cached households, for each row's household name.
  /// Called once for each of the section's two readers, since a stream may take
  /// only one listener. Null shows no names.
  final Stream<List<Household>>? Function()? households;

  /// What the hydrate is doing, when this composition runs one. Null reads as
  /// settled rather than as loading forever.
  final Stream<Hydration>? hydration;

  /// Runs one more hydrate pass, for the failed read's retry. Null offers no
  /// button.
  final Future<void> Function()? onRetry;

  /// Reads the fallback. Null shows the empty text in its place.
  final EventRemoteDataSource? remote;

  /// Says when the fallback is worth reading. Null reads as connected.
  final ConnectivityService? connectivity;

  /// Opens one event, or null where there is nowhere to open it.
  final void Function(BuildContext context, String eventId)? onOpen;

  /// The clock the events are grouped against. Defaults to the device's.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        // Not lazy, so that neither waits for its first reader to start
        // listening to its streams.
        BlocProvider<EventOverviewBloc>(
          lazy: false,
          create: (_) => EventOverviewBloc(
            repository: repository,
            households: households?.call(),
            hydration: hydration,
            onRetry: onRetry,
            now: now,
          ),
        ),
        BlocProvider<UpcomingFallbackCubit>(
          lazy: false,
          create: (_) => UpcomingFallbackCubit(
            remote: remote,
            connectivity: connectivity,
            households: households?.call(),
            now: now,
          ),
        ),
      ],
      child: _Section(
        onOpenEvents: onOpenEvents,
        onOpen: onOpen,
        now: now ?? DateTime.now,
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.onOpenEvents,
    required this.onOpen,
    required this.now,
  });

  final void Function(BuildContext context) onOpenEvents;
  final void Function(BuildContext context, String eventId)? onOpen;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final fallback = context.read<UpcomingFallbackCubit>();

    return BlocListener<EventOverviewBloc, EventOverviewState>(
      listener: (_, state) {
        if (_wantsFallback(state)) {
          fallback.activate();
        } else {
          fallback.deactivate();
        }
      },
      child: ReadAgainWhenUncovered(
        onUncovered: fallback.reload,
        child: BlocBuilder<EventOverviewBloc, EventOverviewState>(
          builder: (context, own) =>
              BlocBuilder<UpcomingFallbackCubit, UpcomingFallbackState>(
                builder: (context, suggested) =>
                    _content(context, own, suggested),
              ),
        ),
      ),
    );
  }

  /// Whether the cache has settled on the user having nothing upcoming. Not
  /// during a first fill, whose later pages may hold them, nor after a failed
  /// pass, which confirms nothing: the user may have events it never reached,
  /// and the fallback's note would be false about them.
  static bool _wantsFallback(EventOverviewState own) =>
      own is EventOverviewReady &&
      own.groups.upcoming.isEmpty &&
      !own.firstFill &&
      !own.refreshFailed;

  Widget _content(
    BuildContext context,
    EventOverviewState own,
    UpcomingFallbackState suggested,
  ) {
    final l10n = EventsLocalizations.of(context);
    final ownRows = switch (own) {
      EventOverviewReady(:final groups) =>
        groups.upcoming.take(UpcomingEventsSection.rowCap).toList(),
      _ => const <EventRow>[],
    };
    final empty = _Message(
      l10n.eventsHomeEmpty,
      textKey: UpcomingEventsSection.emptyKey,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // First, and the same widget in every state, so that the link keeps
        // focus while what's under it changes.
        _Header(hasOwnRows: ownRows.isNotEmpty, onOpenEvents: onOpenEvents),
        const BgeGap.xs(),
        switch (own) {
          EventOverviewLoading() => const _Spinner(),
          EventOverviewError(:final retrying) => _FailedRead(
            retrying: retrying,
          ),
          EventOverviewReady() when ownRows.isNotEmpty => _rows(ownRows),
          EventOverviewReady(firstFill: true) => const _Spinner(),
          EventOverviewReady() when !_wantsFallback(own) => empty,
          EventOverviewReady() => switch (suggested) {
            UpcomingFallbackIdle() ||
            UpcomingFallbackLoading() => const _Spinner(),
            UpcomingFallbackReady(:final rows) when rows.isEmpty => empty,
            UpcomingFallbackReady(:final rows) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Message(
                  l10n.eventsHomeFallbackNote,
                  textKey: UpcomingEventsSection.fallbackNoteKey,
                ),
                _rows(rows),
              ],
            ),
          },
        },
      ],
    );
  }

  /// [rows], each keyed so that a row keeps its focus when one above it leaves.
  Widget _rows(List<EventRow> rows) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, row) in rows.indexed)
          EventRowTile(
            key: UpcomingEventsSection.rowKey(row.event.id),
            row: row,
            now: now,
            onOpen: onOpen,
            separated: index < rows.length - 1,
          ),
      ],
    );
  }
}

/// The heading and the link, side by side where both fit. A [Wrap] so that the
/// link drops below the heading rather than overflowing, as at 200% text on a
/// narrow window.
class _Header extends StatelessWidget {
  const _Header({required this.hasOwnRows, required this.onOpenEvents});

  final bool hasOwnRows;
  final void Function(BuildContext context) onOpenEvents;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return Padding(
      // In line with the rows' titles, which the tiles inset.
      padding: EdgeInsetsDirectional.only(start: BgeTokens.of(context).spaceMd),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            header: true,
            child: Text(
              l10n.eventsHomeHeading,
              key: UpcomingEventsSection.headingKey,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          TextButton(
            key: UpcomingEventsSection.linkKey,
            onPressed: () => onOpenEvents(context),
            child: Text(
              hasOwnRows ? l10n.eventsHomeSeeAll : l10n.eventsHomeYourEvents,
              // "See all" alone doesn't say of what.
              semanticsLabel: hasOwnRows ? l10n.eventsHomeSeeAllSpoken : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => Padding(
    key: UpcomingEventsSection.loadingKey,
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceLg),
    child: const Center(child: EventLoadingIndicator()),
  );
}

/// The cache couldn't be read, with the retry where a pass can run.
class _FailedRead extends StatelessWidget {
  const _FailedRead({required this.retrying});

  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<EventOverviewBloc>();
    return EventRefreshBanner(
      key: UpcomingEventsSection.errorKey,
      retryKey: UpcomingEventsSection.retryKey,
      failedMessage: EventsLocalizations.of(context).eventsError,
      refreshing: retrying,
      onRetry: bloc.canRetry
          ? () => bloc.add(const EventOverviewRetryRequested())
          : null,
    );
  }
}

/// A line of text in line with the rows' titles. A live region, because it
/// takes the place of the spinner, which said it was loading.
class _Message extends StatelessWidget {
  const _Message(this.text, {required this.textKey});

  final String text;
  final Key textKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: BgeTokens.of(context).spaceMd),
    child: Semantics(
      container: true,
      liveRegion: true,
      child: Text(
        text,
        key: textKey,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ),
  );
}
