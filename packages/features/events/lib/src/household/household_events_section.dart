import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_overview_bloc.dart';
import 'package:events/src/bloc/event_overview_event.dart';
import 'package:events/src/bloc/event_overview_state.dart';
import 'package:events/src/overview/event_groups.dart';
import 'package:events/src/sync/household_events_sync.dart';
import 'package:events/src/widgets/event_row.dart';
import 'package:events/src/widgets/event_section_states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A household's upcoming events, on the household's screen (#503): the
/// events this user can see in the household, from the cache, soonest first.
/// The household screen draws the heading above it and the New event row
/// below it, so this draws neither.
///
/// ## The server's list, with its upcoming rule applied again
///
/// The rows are the events the household's list sent this user, as
/// [HouseholdEventsSync]'s passes cached them, and no others. The user's own
/// events in this household that the list didn't send are not added, so the
/// section stays the household's list rather than a mix of two.
///
/// That list holds the events with a confirmed date still to come, and the
/// section applies the same rule again, through [groupEvents] against the
/// clock. An event whose last date ends while the screen is open leaves at
/// that instant, with nothing read or written. A cached row that is past, or
/// back to choosing a date, isn't shown while it waits for a pass to find it
/// gone. The empty text says "with a confirmed date" because of that rule:
/// the list leaves out events still choosing one, so "no events" would be
/// false.
///
/// Nor is a cancelled row shown. The list never sends a cancelled event
/// (#503), so a row the user has just cancelled from its screen would
/// otherwise stay up, marked cancelled, until a pass purged it. Home's shelf
/// leaves cancelled rows off too.
///
/// A row names no household. Every row is this household's, under a heading
/// that says so.
///
/// ## When it reads
///
/// Opening the section starts a pass through [sync], and so does coming back
/// to it from a route that covered it, as the household's invites entry
/// reads again. An event made from the New event row below it is then
/// listed on the way back, where the household's list sends it. The retries
/// start another pass. Nothing else does: it isn't part of the session's
/// hydrate, which would read every household's events at each sign-in for a
/// screen the user may never open. Offline, it shows what's cached. Without a
/// [sync] it shows the cache, offers no retry, and reads nothing when
/// uncovered.
///
/// The pass on the way back is one that starts then. A pass still running
/// from the open is waited out, not joined, as its answer may predate the
/// event: landing, it would leave the event out with no retry to press. The
/// retries join a running pass, which is what one pressed during it wants.
///
/// A pass started by uncovering is one the user didn't ask for, so the
/// couldn't-refresh banner keeps its button as it was, and says nothing of
/// it until it lands.
///
/// [repository], [householdId], [sync] and [now] are read once, when the
/// section is first built, and new ones on a later build change nothing. A
/// host keys the section on them instead, so that new ones build a new
/// section with its own bloc and its own pass: the household screen keys it
/// by household id, and the shell by repository. The [sync] lives as long as
/// the session's repository does, so a new repository comes with a new sync.
///
/// ## The states
///
/// The overview's bloc (`EventOverviewBloc`) drives it, so the first fill,
/// the clock and the retry behave as they do on the overview.
///
/// - **A spinner** until the cache answers, or while the first pass runs and
///   no cached row would be shown. Without a [sync] there is no pass to wait
///   for, so an empty cache shows the empty text. Household rows can all be
///   past, planning or cancelled while it runs, and the pass may be about to
///   write upcoming ones, so "no upcoming events" would be a claim no pass
///   has made. Home's section waits the same way.
/// - **The rows, or the empty text**, once the cache answers.
/// - **The couldn't-refresh banner** above either, after a failed pass, since
///   what's shown may be out of date. While a retry the user asked for runs,
///   the banner says so and its button keeps focus. A retry over a first fill
///   that left the cache empty is the exception: the section returns to the
///   spinner, so there is no banner to keep it.
/// - **The failed read** in place of all of them, with a retry where a pass
///   can run. The retry also reads the cache again.
///
/// The banner has its own place above the content, so the rows keep their
/// elements as it comes and goes. Each row's key is its event's, on a wrapper
/// around the row, so a row keeps its element and its focus when one above it
/// leaves (#549), as a pass's purge can make one do.
///
/// ## Rows open the detail
///
/// A row shows the event as the overview's row does, with the user's answer,
/// and [onOpen] opens the event's screen, where RSVP is (#508). Rows have no
/// RSVP control of their own, which would copy #508's controls, and their
/// focus and offline rules, into a second place. Nor do they say when the
/// user answered, a date the server gets wrong after a Maybe (backend#1027).
/// Joining an event is #668. Without [onOpen] a row is inert content.
class HouseholdEventsSection extends StatefulWidget {
  const HouseholdEventsSection({
    required this.repository,
    required this.householdId,
    this.sync,
    this.onOpen,
    this.now,
    super.key,
  });

  /// Key on the spinner.
  static const Key loadingKey = Key('household_events.loading');

  /// Key on the text saying nothing's coming up.
  static const Key emptyKey = Key('household_events.empty');

  /// Key on the failed cache read's banner.
  static const Key errorKey = Key('household_events.error');

  /// Key on the failed read's retry button.
  static const Key errorRetryKey = Key('household_events.error_retry');

  /// Key on the couldn't-refresh banner's retry button.
  static const Key refreshRetryKey = Key('household_events.refresh_retry');

  /// Per-row key, on the wrapper around the row:
  /// `household_events.row_<eventId>`.
  static Key rowKey(String eventId) => Key('household_events.row_$eventId');

  /// The user-session event repository. Read-only here: the passes write the
  /// cache, and this only watches it.
  final EventRepository repository;

  /// The household whose events these are.
  final String householdId;

  /// Runs the household's passes and says how they went. Null shows the
  /// cache as settled and offers no retry.
  final HouseholdEventsSync? sync;

  /// Opens one event, or null where there is nowhere to open it.
  final void Function(BuildContext context, String eventId)? onOpen;

  /// The clock the events are grouped against. Defaults to the device's.
  final DateTime Function()? now;

  @override
  State<HouseholdEventsSection> createState() => _HouseholdEventsSectionState();
}

class _HouseholdEventsSectionState extends State<HouseholdEventsSection> {
  late final DateTime Function() _now;
  late final EventOverviewBloc _bloc;

  /// Starts a pass for the household, or null without a sync.
  late final Future<void> Function()? _refresh;

  /// Starts a pass for the household once any running one ends, or null
  /// without a sync.
  late final Future<void> Function()? _refreshAfterChange;

  @override
  void initState() {
    super.initState();
    final HouseholdEventsSection(:repository, :householdId, :sync) = widget;
    _now = widget.now ?? DateTime.now;
    _refresh = sync == null ? null : () => sync.refresh(householdId);
    _refreshAfterChange = sync == null
        ? null
        : () => sync.refreshAfterChange(householdId);
    _bloc = EventOverviewBloc(
      repository: repository,
      logger: BgeLogger('bge.events.household'),
      items: () => repository.watchHouseholdEventListItems(householdId),
      hydration: sync?.watch(householdId),
      onRetry: _refresh,
      now: _now,
    );
    unawaited(_refresh?.call());
  }

  @override
  void dispose() {
    unawaited(_bloc.close());
    super.dispose();
  }

  void _retry() => _bloc.add(const EventOverviewRetryRequested());

  @override
  Widget build(BuildContext context) {
    final section = BlocBuilder<EventOverviewBloc, EventOverviewState>(
      bloc: _bloc,
      builder: _content,
    );
    final refresh = _refreshAfterChange;
    if (refresh == null) return section;
    return ReadAgainWhenUncovered(
      onUncovered: () => unawaited(refresh()),
      child: section,
    );
  }

  Widget _content(BuildContext context, EventOverviewState state) {
    final l10n = EventsLocalizations.of(context);
    final retry = _bloc.canRetry ? _retry : null;
    // Every row the section shows, and what decides between the rows, the
    // empty text and the first fill's spinner. The household's list never
    // sends a cancelled event (#503).
    final rows = switch (state) {
      EventOverviewReady(:final groups) => groups.stillHappening,
      _ => const <EventRow>[],
    };
    final spinner = EventSectionSpinner(
      key: HouseholdEventsSection.loadingKey,
      label: l10n.householdEventsLoading,
    );
    final Widget content = switch (state) {
      EventOverviewLoading() => spinner,
      EventOverviewError(:final retrying) => BgeRefreshBanner(
        key: HouseholdEventsSection.errorKey,
        retryKey: HouseholdEventsSection.errorRetryKey,
        failedMessage: l10n.householdEventsLoadFailed,
        inProgressLabel: l10n.eventsRefreshInProgress,
        retryLabel: l10n.eventsRefreshRetry,
        refreshing: retrying,
        onRetry: retry,
      ),
      EventOverviewReady() when rows.isNotEmpty => _Rows(
        rows: rows,
        now: _now,
        onOpen: widget.onOpen,
      ),
      EventOverviewReady(firstFill: true) => spinner,
      EventOverviewReady() => EventSectionMessage(
        l10n.householdEventsEmpty,
        textKey: HouseholdEventsSection.emptyKey,
      ),
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state
            case EventOverviewReady(:final refreshFailed, :final refreshing)
            when refreshFailed || refreshing) ...[
          BgeRefreshBanner(
            retryKey: HouseholdEventsSection.refreshRetryKey,
            failedMessage: l10n.householdEventsRefreshFailed,
            inProgressLabel: l10n.eventsRefreshInProgress,
            retryLabel: l10n.eventsRefreshRetry,
            refreshing: refreshing,
            onRetry: retry,
          ),
          const BgeGap.md(),
        ],
        content,
      ],
    );
  }
}

/// The upcoming rows, each keyed on a wrapper so that it keeps its element
/// when one above it leaves.
class _Rows extends StatelessWidget {
  const _Rows({required this.rows, required this.now, required this.onOpen});

  final List<EventRow> rows;
  final DateTime Function() now;
  final void Function(BuildContext context, String eventId)? onOpen;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final row in rows)
        KeyedSubtree(
          key: HouseholdEventsSection.rowKey(row.event.id),
          child: EventRowTile(
            row: row,
            now: now,
            onOpen: onOpen,
            separated: !identical(row, rows.last),
          ),
        ),
    ],
  );
}
