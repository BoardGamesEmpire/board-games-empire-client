import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_overview_bloc.dart';
import 'package:events/src/bloc/event_overview_event.dart';
import 'package:events/src/bloc/event_overview_state.dart';
import 'package:events/src/home/upcoming_fallback_cubit.dart';
import 'package:events/src/overview/event_groups.dart';
import 'package:events/src/widgets/event_card.dart';
import 'package:events/src/widgets/event_section_states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hydration/hydration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

/// The home page's upcoming events (#613): the user's next few events, or, with
/// none of their own, what's coming up that they could see. They sit side by
/// side in a row that moves, a [BgeShelf] like the game shelves below it
/// (#669), one [EventCard] each.
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
/// ## One row in every state
///
/// The shelf is there whatever the state, so its header, and the link in it,
/// stays the same element. A state with nothing to show puts its spinner,
/// banner or text in the row's place. The fallback's note sits between the
/// heading and the cards, so it doesn't scroll away with them. The row returns
/// to its start when its source changes, as when the user's own event replaces
/// the fallback, because what was in view has gone.
///
/// The cards are as tall as the tallest, so their outlines end in a line. Each
/// is told the row's width, which a card in a horizontal scroll view can't
/// measure, so that at 200% text one card fills the row rather than running
/// past it.
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

  /// The most events the section shows, in either state.
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

  /// Key on the line above the fallback's cards.
  static const Key fallbackNoteKey = Key('events.home_fallback_note');

  /// Per-card key: `events.home_row_<eventId>`.
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
      own.groups.stillHappening.isEmpty &&
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
        groups.stillHappening.take(UpcomingEventsSection.rowCap).toList(),
      _ => const <EventRow>[],
    };
    final spinner = EventSectionSpinner(
      key: UpcomingEventsSection.loadingKey,
      label: l10n.eventsLoading,
    );
    final empty = EventSectionMessage(
      l10n.eventsHomeEmpty,
      textKey: UpcomingEventsSection.emptyKey,
    );

    // A state with nothing to show: its placeholder, and no note or rows.
    (Widget?, Widget?, List<EventRow>) only(Widget placeholder) =>
        (placeholder, null, const []);

    final (placeholder, note, rows) = switch (own) {
      EventOverviewLoading() => only(spinner),
      EventOverviewError(:final retrying) => only(
        _FailedRead(retrying: retrying),
      ),
      EventOverviewReady() when ownRows.isNotEmpty => (null, null, ownRows),
      EventOverviewReady(firstFill: true) => only(spinner),
      EventOverviewReady() when !_wantsFallback(own) => only(empty),
      EventOverviewReady() => switch (suggested) {
        UpcomingFallbackIdle() || UpcomingFallbackLoading() => only(spinner),
        UpcomingFallbackReady(:final rows) when rows.isEmpty => only(empty),
        UpcomingFallbackReady(:final rows) => (
          null,
          EventSectionMessage(
            l10n.eventsHomeFallbackNote,
            textKey: UpcomingEventsSection.fallbackNoteKey,
          ),
          rows,
        ),
      },
    };

    // A card can't measure the row it sits in, so the row's width is read
    // here, around the shelf, and handed to each card.
    return LayoutBuilder(
      builder: (context, constraints) => BgeShelf(
        heading: l10n.eventsHomeHeading,
        headingKey: UpcomingEventsSection.headingKey,
        previousLabel: l10n.eventsHomePrevious,
        nextLabel: l10n.eventsHomeNext,
        // The same in every state, so that the link keeps focus while what's
        // under it changes.
        actions: [
          _Link(hasOwnRows: ownRows.isNotEmpty, onOpenEvents: onOpenEvents),
        ],
        placeholder: placeholder,
        note: note,
        // Back to the start when the user's own events take the fallback's
        // place, or give it back.
        resetToken: ownRows.isNotEmpty,
        equalHeights: true,
        children: [
          // Keyed, so that a card keeps its focus when one before it leaves.
          for (final row in rows)
            EventCard(
              key: UpcomingEventsSection.rowKey(row.event.id),
              row: row,
              now: now,
              maxWidth: constraints.maxWidth,
              onOpen: onOpen,
            ),
        ],
      ),
    );
  }
}

/// The link to the events screen, in the shelf's header.
class _Link extends StatelessWidget {
  const _Link({required this.hasOwnRows, required this.onOpenEvents});

  final bool hasOwnRows;
  final void Function(BuildContext context) onOpenEvents;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return TextButton(
      key: UpcomingEventsSection.linkKey,
      onPressed: () => onOpenEvents(context),
      child: Text(
        hasOwnRows ? l10n.eventsHomeSeeAll : l10n.eventsHomeYourEvents,
        // "See all" alone doesn't say of what.
        semanticsLabel: hasOwnRows ? l10n.eventsHomeSeeAllSpoken : null,
      ),
    );
  }
}

/// The cache couldn't be read, with the retry where a pass can run.
class _FailedRead extends StatelessWidget {
  const _FailedRead({required this.retrying});

  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<EventOverviewBloc>();
    final l10n = EventsLocalizations.of(context);
    return BgeRefreshBanner(
      key: UpcomingEventsSection.errorKey,
      retryKey: UpcomingEventsSection.retryKey,
      failedMessage: l10n.eventsError,
      inProgressLabel: l10n.eventsRefreshInProgress,
      retryLabel: l10n.eventsRefreshRetry,
      refreshing: retrying,
      onRetry: bloc.canRetry
          ? () => bloc.add(const EventOverviewRetryRequested())
          : null,
    );
  }
}
