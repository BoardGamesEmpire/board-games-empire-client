import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/event_actions_bloc.dart';
import '../bloc/event_actions_event.dart';
import '../bloc/event_actions_state.dart';
import '../bloc/event_detail_bloc.dart';
import '../bloc/event_detail_event.dart';
import '../bloc/event_detail_state.dart';
import '../detail/event_actions.dart';
import '../widgets/event_detail_sections.dart';
import '../widgets/event_refresh_banner.dart';

/// One event (#498): its header, its dates, who's coming and its games, read
/// reactively from the local cache and from the server once per open.
///
/// The household detail's shape: the caller resolves the repository, the
/// optional server and streams and the callbacks, and the screen owns its
/// blocs: the detail's ([EventDetailBloc], whose class doc has the state
/// table) and, where Delete can be offered, the actions'
/// ([EventActionsBloc]). Loading, not found and error are short centred
/// pages. Ready is one scrolling page, with the couldn't-refresh banner over
/// the cached event where the last read failed.
///
/// ## What it doesn't show yet
///
/// Most actions. The bloc works out what the viewer may do, and the app
/// bar's menu offers Delete (#501) to a viewer the role table gives it. The
/// other actions' issues (#500, #502–#518) add theirs. The games section says
/// the event's games will show there, until #519 has something to show.
///
/// ## Delete
///
/// An [EventActionsBloc] beside the detail's sends it (#501), straight to the
/// server, after a dialog that says it can't be undone and that nobody on the
/// event is told. It is offered only with a [remote] and an [onBack]: the
/// delete is never queued, and once the event is gone a screen that can't
/// leave has nowhere to go.
///
/// Delete waits for the detail read, and the refresh banner's retry waits
/// for the delete: a read's answer landing after the delete would cache the
/// event again. Done leaves with a snackbar, and the page holds its last
/// frame while the route leaves, since the removal's null would otherwise
/// draw not found under the exit. A done that lands under another route
/// stays, and falls to not found for the user to find on their way back.
/// Gone, refused and failed each show a
/// banner over the event, and the screen reads the event again where
/// [EventActionOutcome.rereads] says to.
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

  /// Key on the app bar's More actions button (#501).
  static const Key moreActionsKey = Key('event_detail.more_actions');

  /// Key on the menu's Delete item.
  static const Key deleteKey = Key('event_detail.delete');

  /// Key on the delete dialog's confirm button.
  static const Key deleteConfirmKey = Key('event_detail.delete_confirm');

  /// Key on the banner saying how the last action went.
  static const Key actionOutcomeKey = Key('event_detail.action_outcome');

  /// The event to show.
  final String eventId;

  /// The user-session event repository, which the screen's read and delete
  /// write to.
  final EventRepository repository;

  /// The per-server event client, for the read every open makes, the retry
  /// and the delete (#501). Null reads nothing and offers neither a retry nor
  /// Delete: the screen shows the cache alone.
  final EventRemoteDataSource? remote;

  /// Whether the session is still the user [repository] belongs to, asked
  /// before the read or the delete goes out and before the read's answer is
  /// written (#432). Null, as on native, is always yes.
  final Future<bool> Function()? confirmSession;

  /// The cached households, for the header's household name. Null names
  /// none, and is never waited on.
  final Stream<List<Household>>? households;

  /// The viewer's role in a household, for what they may do to its events
  /// without attending. Null gives household roles no say.
  final Future<HouseholdRole?> Function(String householdId)? householdRole;

  /// Returns to the events, with this screen's context: from the not-found
  /// state, as that surface's primary action, and after a delete (#501). The
  /// feature package doesn't know the route table. Null offers neither that
  /// button nor Delete, and the app bar's back button still leaves.
  final void Function(BuildContext context)? onBack;

  /// The clock that decides whether a date is this year's. Defaults to the
  /// device's.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final remote = this.remote;
    final hasActions = remote != null && onBack != null;

    return MultiBlocProvider(
      // go_router keeps this page when only the id changes; the key makes a
      // new id new blocs rather than the old event under them, as the
      // household detail's does (#466).
      key: ValueKey<String>(eventId),
      providers: [
        BlocProvider<EventDetailBloc>(
          create: (_) => EventDetailBloc(
            eventId: eventId,
            repository: repository,
            remote: remote,
            confirmSession: confirmSession,
            households: households,
            householdRole: householdRole,
          ),
        ),
        // None without a server or a way back, and then nothing offers
        // Delete.
        if (hasActions)
          BlocProvider<EventActionsBloc>(
            create: (_) => EventActionsBloc(
              repository: repository,
              remote: remote,
              confirmSession: confirmSession,
            ),
          ),
      ],
      child: _EventDetailView(
        onBack: onBack,
        now: now ?? DateTime.now,
        hasActions: hasActions,
      ),
    );
  }
}

class _EventDetailView extends StatelessWidget {
  const _EventDetailView({
    required this.now,
    required this.hasActions,
    this.onBack,
  });

  final DateTime Function() now;
  final void Function(BuildContext context)? onBack;

  /// Whether an [EventActionsBloc] is provided above, which is whether the
  /// screen has a server and a way back. Looking it up where it isn't would
  /// throw.
  final bool hasActions;

  @override
  Widget build(BuildContext context) {
    final page = BlocBuilder<EventDetailBloc, EventDetailState>(
      // Once the delete is done the screen is leaving, and the route's exit
      // keeps it mounted while it goes. The removal's null would draw not
      // found under the exit, so the page holds its last frame instead.
      // Unless another route covers it, which the screen stays under.
      buildWhen: hasActions
          ? (_, _) =>
                !_deleted(context.read<EventActionsBloc>().state) ||
                _covered(context)
          : null,
      builder: (context, state) {
        // A delete done or found gone removes the event, and the screen
        // falls to not found, as after a read's 404 (#501). The detail
        // derives that from the removal's null only where its last read went
        // through: after one that failed it derives the couldn't-load page,
        // whose retry would read an event the server has just said is gone.
        if (hasActions &&
            state is! EventDetailReady &&
            _removed(context.read<EventActionsBloc>().state)) {
          return _NotFoundPage(onBack: onBack);
        }

        return switch (state) {
          EventDetailLoading() => const _LoadingPage(),
          EventDetailNotFound() => _NotFoundPage(onBack: onBack),
          EventDetailError(:final refreshing, :final canRetry) => _ErrorPage(
            refreshing: refreshing,
            canRetry: canRetry,
          ),
          EventDetailReady() => _ReadyPage(
            state: state,
            now: now,
            hasActions: hasActions,
          ),
        };
      },
    );
    if (!hasActions) return page;

    return BlocListener<EventActionsBloc, EventActionsState>(
      // Only a request's end emits an outcome, and a dismissal clears it.
      listenWhen: (previous, current) =>
          current.outcome != null && current.outcome != previous.outcome,
      listener: _onOutcome,
      child: page,
    );
  }

  void _onOutcome(BuildContext context, EventActionsState state) {
    final outcome = state.outcome;
    if (outcome == null) return;
    if (_deleted(state)) {
      // The messenger is the app's, so the snackbar outlives this route and
      // shows on the screen it leaves for.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(EventsLocalizations.of(context).eventsDeleted)),
      );
      // Only from the top. Busy shows nothing, so while the DELETE was out
      // the user may have pressed back, and the route stays mounted through
      // its exit, or opened another route over it. The app's way back pops
      // whichever route is on top, so either way it would pop another. A
      // covered screen stays, and shows not found once the removal lands.
      if (ModalRoute.isCurrentOf(context) ?? true) onBack!(context);
      return;
    }
    if (outcome.rereads) _retry(context);
  }
}

/// Whether [state] holds a delete the server accepted. The screen is leaving
/// then, and offers nothing that would start another request.
bool _deleted(EventActionsState state) =>
    state.outcome?.action == EventAction.delete &&
    state.outcome?.result == EventActionResult.done;

/// Whether [state] holds a delete the server accepted or found gone: either
/// way it has no live event with that id, and the event leaves the cache.
bool _removed(EventActionsState state) =>
    state.outcome?.action == EventAction.delete &&
    (state.outcome?.result == EventActionResult.done ||
        state.outcome?.result == EventActionResult.gone);

/// Whether another route is over this screen's: still in the stack, but not
/// on top. Null, with no route, is not covered.
bool _covered(BuildContext context) =>
    (ModalRoute.isActiveOf(context) ?? false) &&
    !(ModalRoute.isCurrentOf(context) ?? true);

/// The event itself.
class _ReadyPage extends StatelessWidget {
  const _ReadyPage({
    required this.state,
    required this.now,
    required this.hasActions,
  });

  final EventDetailReady state;
  final DateTime Function() now;

  /// Whether an [EventActionsBloc] is provided above.
  final bool hasActions;

  @override
  Widget build(BuildContext context) {
    if (!hasActions) return _build(context, null);

    return BlocBuilder<EventActionsBloc, EventActionsState>(builder: _build);
  }

  /// [actionsState] is null where there is no actions bloc, and then nothing
  /// offers Delete.
  Widget _build(BuildContext context, EventActionsState? actionsState) {
    final l10n = EventsLocalizations.of(context);
    final snapshot = state.detail.snapshot;
    final event = snapshot.event;
    final outcome = actionsState?.outcome;
    // A request on its way, or a delete done and the screen leaving.
    final acting =
        actionsState != null && (actionsState.busy || _deleted(actionsState));

    return BgePage(
      // The section name, not the event's: the title is the page's heading
      // below, where a long one wraps rather than being cut short.
      title: Text(l10n.eventsTitle),
      actions: [
        if (actionsState != null && state.actions.contains(EventAction.delete))
          _ActionsMenu(
            title: event.title,
            // Not while a read runs, whose answer landing after the delete
            // would cache the event again (#501). Nor while a request is out
            // or once the delete is done, when a press would send another.
            canDelete: !state.reading && !acting,
          ),
      ],
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
              // No read while the delete is out or done: its answer could land
              // after the removal and cache the event again (#501).
              onRetry: state.canRetry && !acting ? () => _retry(context) : null,
            ),
            const BgeGap.lg(),
          ],
          // Done has no banner: the screen leaves with a snackbar.
          if (outcome != null && outcome.result != EventActionResult.done) ...[
            _ActionOutcomeBanner(outcome: outcome),
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

/// The app bar's More actions menu (#501), holding Delete. #502's actions
/// join it.
class _ActionsMenu extends StatelessWidget {
  const _ActionsMenu({required this.title, required this.canDelete});

  /// The event's title, for the dialog's.
  final String title;

  /// Whether Delete may be pressed now. When it may not, it stays in the
  /// menu, disabled, rather than leaving the menu empty.
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return MenuAnchor(
      // Left unconstrained, the panel sits in a hard-clipped box as wide as
      // its widest entry, which at 2.0 text runs past a phone's edge. Held
      // to the screen, the entries wrap instead.
      crossAxisUnconstrained: false,
      menuChildren: [
        MenuItemButton(
          key: EventDetailScreen.deleteKey,
          overflowAxis: Axis.vertical,
          onPressed: canDelete ? () => unawaited(_delete(context)) : null,
          child: Text(l10n.eventsDetailDelete),
        ),
      ],
      builder: (context, controller, _) => MergeSemantics(
        child: Semantics(
          expanded: controller.isOpen,
          child: IconButton(
            key: EventDetailScreen.moreActionsKey,
            icon: const Icon(Icons.more_vert),
            tooltip: l10n.eventsDetailMoreActions,
            onPressed: controller.isOpen ? controller.close : controller.open,
          ),
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    // Read before the dialog opens: the page under it can rebuild without
    // this menu, and take the context it was asked from with it.
    final actions = context.read<EventActionsBloc>();
    final detail = context.read<EventDetailBloc>();
    if (!await _confirmDelete(context) || actions.isClosed) return;

    // A read can have started while the dialog was open, and Delete waits
    // for it (#501). The id is the detail's, not the one the screen was
    // opened on, which a reconcile can have moved (#499).
    final state = detail.state;
    if (state is! EventDetailReady || state.reading) return;
    actions.add(EventDeleteRequested(state.detail.snapshot.event.id));
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final l10n = EventsLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // At 2.0 text a long title and the body can outgrow a phone's height.
        scrollable: true,
        title: Text(l10n.eventsDeleteConfirmTitle(title)),
        content: Text(l10n.eventsDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.eventsDeleteConfirmKeep),
          ),
          TextButton(
            key: EventDetailScreen.deleteConfirmKey,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.eventsDeleteConfirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

/// How the last action went (#501), over the event until dismissed or
/// replaced. A live region, as every [BgeInlineBanner] is. Done has none:
/// the screen leaves.
class _ActionOutcomeBanner extends StatelessWidget {
  const _ActionOutcomeBanner({required this.outcome});

  final EventActionOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return BgeInlineBanner(
      key: EventDetailScreen.actionOutcomeKey,
      tone: switch (outcome.result) {
        // Gone is what deleting asked for.
        EventActionResult.done ||
        EventActionResult.gone => BgeBannerTone.success,
        EventActionResult.refused => BgeBannerTone.warning,
        EventActionResult.failed => BgeBannerTone.error,
      },
      // Delete is the only action yet. #502's add their own copy.
      message: switch (outcome.result) {
        EventActionResult.done => l10n.eventsDeleted,
        EventActionResult.gone => l10n.eventsDeleteGone,
        EventActionResult.refused => l10n.eventsDeleteRefused,
        // Only a transient failure is worth pressing again (#501). A session
        // that moved and a cache that couldn't be read sent nothing, and a
        // 4xx was refused: the same press would end the same way.
        EventActionResult.failed =>
          outcome.error is EventRemoteTransientException
              ? l10n.eventsDeleteFailed
              : l10n.eventsDeleteFailedUnexpected,
      },
      action: TextButton(
        onPressed: () => context.read<EventActionsBloc>().add(
          const EventActionOutcomeDismissed(),
        ),
        child: Text(l10n.eventsActionDismiss),
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

/// The only event the screen sends the detail bloc (#498): read the event
/// again.
void _retry(BuildContext context) =>
    context.read<EventDetailBloc>().add(const EventDetailRetryRequested());
