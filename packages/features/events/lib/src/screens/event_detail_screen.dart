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
import '../bloc/event_poll_bloc.dart';
import '../bloc/event_poll_event.dart';
import '../bloc/event_poll_state.dart';
import '../detail/event_actions.dart';
import '../detail/event_date_actions.dart';
import '../detail/event_poll.dart';
import '../widgets/event_date_dialogs.dart';
import '../widgets/event_date_poll.dart';
import '../widgets/event_detail_sections.dart';
import '../widgets/event_labels.dart';
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
/// bar's menu offers Delete (#501), the dates their own (#506), and a poll's
/// dates their answers (#507), to a viewer the role table gives them. The
/// other actions' issues (#500, #502–#518) add theirs. The games section
/// says the event's games will show there, until #519 has something to
/// show.
///
/// ## Delete
///
/// An [EventActionsBloc] beside the detail's sends it (#501), straight to the
/// server, after a dialog that says it can't be undone and that nobody on the
/// event is told. It is offered only with a [remote] and an [onBack]: the
/// delete is never queued, and once the event is gone a screen that can't
/// leave has nowhere to go. The dates' actions share the bloc, so they are
/// offered only there too.
///
/// Delete waits for the detail read, and the refresh banner's retry waits
/// for the delete: a read's answer landing after the delete would cache the
/// event again. A read that starts while the dialog is open holds the
/// delete back until it ends, and the delete is then sent if the event is
/// still there to delete. Done leaves with a snackbar, and the page holds its last
/// frame while the route leaves, since the removal's null would otherwise
/// draw not found under the exit. A done that lands under another route
/// stays, and falls to not found for the user to find on their way back.
/// Gone, refused and failed each show a
/// banner over the event, and the screen reads the event again where
/// [EventActionOutcome.rereads] says to.
///
/// ## Dates
///
/// Each date has a menu of what its status and the viewer's role allow, and
/// *Add a date* sits under the dates where the event takes another (#506).
/// Each choice opens its dialog. If a read started while it was open, the
/// request waits for that read to end, as Delete's does, since the read's
/// answer landing after the write would put the date back as it was
/// (#589). Dropped, an add or edit would take what the user typed with it.
/// It is sent with the id of the event the screen shows then, and not at
/// all if that event was cancelled or archived meanwhile, which the server
/// would still let a date be edited or removed on (backend#956), or if the
/// viewer's role no longer allows it, which for a confirm, decline or
/// cancel the server doesn't check (backend#979). Removing a
/// Confirmed date asks once, and is a cancel and then a remove (#446).
///
/// Every end shows a banner, done included, since the screen stays, and
/// each is read again as [EventActionOutcome.rereads] says: the server
/// derives the event's status from its dates.
///
/// On a poll, Confirm offers to decline the other proposed dates in the
/// same step (#507). The dates declined are the others proposed as the
/// event stands once the confirm is sent.
///
/// ## The poll
///
/// On a poll with a proposed date, each proposed date shows the viewer's
/// answer, its tallies, the leader's mark and how many haven't answered,
/// from an [EventPollBloc] beside the actions' (#507). The summary isn't
/// cached, so it is read when the poll first shows and again each time a
/// detail read ends, for the event the detail shows then and only while
/// it still shows a poll the server knows. Offline, the dates show from
/// the cache and the poll says it couldn't load, with a retry.
///
/// A vote goes out at once, and waits for no read: no read can overwrite
/// it, so the chips stay enabled while one runs, and a keyboard user on one
/// keeps their place. They wait for a date write or Delete, as the dates'
/// menus do, and for the viewer's own answers to be read. A vote's end other
/// than done shows a banner of its own, and reads the event again where
/// [EventActionOutcome.rereads] says to: a date no longer open for answers
/// has been confirmed, declined or cancelled meanwhile. A poll read that
/// finds the event gone reads it again too, since nothing else would tell
/// the screen. Either read waits for a date write or Delete to end (#589),
/// and isn't made once the event is deleted (#501). *Who answered* opens a
/// page of everyone's answers, through [onWhoAnswered], where the roster
/// can be read.
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
    this.onWhoAnswered,
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

  /// Key on a date's menu button (#506), by the date's id.
  static Key dateMenuKey(String occurrenceId) =>
      Key('event_detail.date_menu_$occurrenceId');

  /// Key on one item of a date's menu.
  static Key dateActionKey(String occurrenceId, EventAction action) =>
      Key('event_detail.date_${action.name}_$occurrenceId');

  /// Key on the dates' *Add a date* button.
  static const Key addDateKey = Key('event_detail.add_date');

  /// Key on one of a proposed date's answer chips (#507).
  static Key pollAnswerKey(
    String occurrenceId,
    AvailabilityResponse response,
  ) => Key('event_detail.poll_${response.name}_$occurrenceId');

  /// Key on a proposed date's tallies line.
  static Key pollTalliesKey(String occurrenceId) =>
      Key('event_detail.poll_tallies_$occurrenceId');

  /// Key on a proposed date's leader mark: the leader, or tied.
  static Key pollLeaderKey(String occurrenceId) =>
      Key('event_detail.poll_leader_$occurrenceId');

  /// Key on *Confirm this date*, under the leading date.
  static Key confirmLeaderKey(String occurrenceId) =>
      Key('event_detail.confirm_leader_$occurrenceId');

  /// Key on the banner saying how the last vote went.
  static const Key pollOutcomeKey = Key('event_detail.poll_outcome');

  /// Key on the retry of a poll read that failed.
  static const Key pollRetryKey = Key('event_detail.poll_retry');

  /// Key on the dates' *Who answered* button.
  static const Key whoAnsweredKey = Key('event_detail.who_answered');

  /// Key on the Confirm dialog's *Also decline the other proposed dates*:
  /// the dialog's own key, named here beside the screen's others.
  static const Key declineOthersKey = EventDateDialogKeys.declineOthers;

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

  /// Opens the page of who answered the poll (#507), with this screen's
  /// context: the feature package doesn't know the route table. Null
  /// offers no *Who answered*, as does a roster that isn't read yet or isn't
  /// visible.
  final void Function(BuildContext context)? onWhoAnswered;

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
        // Delete, a date's actions or the poll.
        if (hasActions) ...[
          BlocProvider<EventActionsBloc>(
            create: (_) => EventActionsBloc(
              repository: repository,
              remote: remote,
              confirmSession: confirmSession,
            ),
          ),
          BlocProvider<EventPollBloc>(
            create: (_) =>
                EventPollBloc(remote: remote, confirmSession: confirmSession),
          ),
        ],
      ],
      child: _EventDetailView(
        onBack: onBack,
        onWhoAnswered: onWhoAnswered,
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
    this.onWhoAnswered,
  });

  final DateTime Function() now;
  final void Function(BuildContext context)? onBack;
  final void Function(BuildContext context)? onWhoAnswered;

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
            onWhoAnswered: onWhoAnswered,
          ),
        };
      },
    );
    if (!hasActions) return page;

    return MultiBlocListener(
      listeners: [
        BlocListener<EventActionsBloc, EventActionsState>(
          // Only a request's end emits an outcome, and a dismissal clears it.
          listenWhen: (previous, current) =>
              current.outcome != null && current.outcome != previous.outcome,
          listener: _onOutcome,
        ),
        BlocListener<EventDetailBloc, EventDetailState>(
          listenWhen: _pollDue,
          listener: (context, state) => _readPoll(context, state),
        ),
        BlocListener<EventPollBloc, EventPollState>(
          // A vote's end the bloc announces, as the actions' outcomes are.
          listenWhen: (previous, current) =>
              current.outcome != null && current.outcome != previous.outcome,
          listener: (context, state) {
            if (state.outcome?.rereads ?? false) {
              unawaited(_rereadForPoll(context));
            }
          },
        ),
        BlocListener<EventPollBloc, EventPollState>(
          // The poll stays gone through its later reads, so a server that
          // answers the event but not its poll can't start a loop of them.
          listenWhen: (previous, current) =>
              previous.load != EventPollLoad.gone &&
              current.load == EventPollLoad.gone,
          listener: (context, _) => unawaited(_rereadForPoll(context)),
        ),
      ],
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

/// Reads the event again after a vote's end that asks for it, or a poll read
/// that found the event gone (#507), once no date write or Delete is out, and
/// not at all once the event is removed.
///
/// A vote or a poll read runs beside the actions' requests, so it can end
/// while one of them is out. A read then could land after the write's answer
/// and put the date back as it was (#589), or cache a deleted event again
/// (#501).
/// The write's own end reads the event where its outcome says to. Where
/// that read is running, the detail drops this one, and the running read
/// shows the date as it is.
Future<void> _rereadForPoll(BuildContext context) async {
  final actions = context.read<EventActionsBloc>();
  final detail = context.read<EventDetailBloc>();
  final ended = actions.state.busy
      ? await actions.stream.firstWhere(
          (state) => !state.busy,
          orElse: () => actions.state,
        )
      : actions.state;
  // The bloc can still read as open just after its provider has gone.
  if (!context.mounted || actions.isClosed || detail.isClosed) return;
  if (_removed(ended)) return;
  detail.add(const EventDetailRetryRequested());
}

/// Whether [state] shows a poll the server can be asked about (#507): one
/// with a proposed date, on an event the server knows. An event created
/// offline has an id the server has never heard of.
bool _pollShows(EventDetailState state) {
  if (state is! EventDetailReady) return false;
  final snapshot = state.detail.snapshot;
  return !snapshot.event.isLocalOnly &&
      showsPoll(snapshot.event, snapshot.occurrences);
}

/// Whether the poll is due a read as the detail goes from [previous] to
/// [current] (#507): it has just started to show, or a detail read has just
/// ended and it still shows. A detail read can change which dates are
/// proposed, and other people's answers come in only when it is read.
bool _pollDue(EventDetailState previous, EventDetailState current) {
  if (!_pollShows(current)) return false;
  if (!_pollShows(previous)) return true;
  return previous is EventDetailReady &&
      current is EventDetailReady &&
      previous.reading &&
      !current.reading;
}

/// Reads the poll of the event [state] shows, by the id it shows then, which
/// a reconcile can move (#499). Only where it shows one.
void _readPoll(BuildContext context, EventDetailState state) {
  if (state is! EventDetailReady || !_pollShows(state)) return;
  context.read<EventPollBloc>().add(
    EventPollRequested(state.detail.snapshot.event.id),
  );
}

/// The event itself.
class _ReadyPage extends StatelessWidget {
  const _ReadyPage({
    required this.state,
    required this.now,
    required this.hasActions,
    this.onWhoAnswered,
  });

  final EventDetailReady state;
  final DateTime Function() now;

  /// Whether an [EventActionsBloc] and an [EventPollBloc] are provided
  /// above.
  final bool hasActions;
  final void Function(BuildContext context)? onWhoAnswered;

  @override
  Widget build(BuildContext context) {
    if (!hasActions) return _build(context, null, null);

    return BlocBuilder<EventActionsBloc, EventActionsState>(
      builder: (context, actionsState) =>
          BlocBuilder<EventPollBloc, EventPollState>(
            builder: (context, pollState) =>
                _build(context, actionsState, pollState),
          ),
    );
  }

  /// [actionsState] and [pollState] are null where there are no such blocs,
  /// and then nothing offers Delete, and no poll shows.
  Widget _build(
    BuildContext context,
    EventActionsState? actionsState,
    EventPollState? pollState,
  ) {
    final l10n = EventsLocalizations.of(context);
    final snapshot = state.detail.snapshot;
    final event = snapshot.event;
    final outcome = actionsState?.outcome;
    final pollOutcome = pollState?.outcome;
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
          // A delete's done has no banner: the screen leaves with a snackbar.
          if (actionsState != null &&
              outcome != null &&
              !_deleted(actionsState)) ...[
            _ActionOutcomeBanner(
              bannerKey: EventDetailScreen.actionOutcomeKey,
              outcome: outcome,
              onDismiss: () => context.read<EventActionsBloc>().add(
                const EventActionOutcomeDismissed(),
              ),
            ),
            const BgeGap.lg(),
          ],
          // A vote's, beside the actions': nothing holds a date write back
          // for a vote that is out, so both can end (#507).
          if (pollOutcome != null) ...[
            _ActionOutcomeBanner(
              bannerKey: EventDetailScreen.pollOutcomeKey,
              outcome: pollOutcome,
              onDismiss: () => context.read<EventPollBloc>().add(
                const EventPollOutcomeDismissed(),
              ),
            ),
            const BgeGap.lg(),
          ],
          EventDetailHeader(
            event: event,
            householdName: state.householdName,
            role: state.detail.attendance?.role,
          ),
          const BgeGap.xl(),
          _Dates(
            state: state,
            now: now,
            hasActions: actionsState != null,
            poll: pollState,
            onWhoAnswered: onWhoAnswered,
            acting: acting,
            // Not while a read runs, whose answer landing after the write
            // would put the date back as it was (#589). Nor while a request
            // is out or once the delete is done.
            enabled: !state.reading && !acting,
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
    // for it to end (#501). The id is the detail's then, not the one the
    // screen was opened on, which a reconcile can have moved (#499).
    final state = await _readEnded(detail);
    if (state is! EventDetailReady || actions.isClosed) return;
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

/// The dates section (#498), with each date's menu and *Add a date* where
/// the viewer may use them (#506), and a poll's answers (#507). See
/// [EventDetailScreen] on how a choice is sent.
class _Dates extends StatelessWidget {
  const _Dates({
    required this.state,
    required this.now,
    required this.hasActions,
    required this.enabled,
    required this.acting,
    this.poll,
    this.onWhoAnswered,
  });

  final EventDetailReady state;
  final DateTime Function() now;

  /// Whether an [EventActionsBloc] is provided above. Without one the dates
  /// offer nothing.
  final bool hasActions;

  /// Whether the controls may be pressed now.
  final bool enabled;

  /// Whether a date write or Delete is out, or the delete is done. All that
  /// holds the poll's answers: see [EventDetailScreen].
  final bool acting;

  /// The poll's state, or null where there is no [EventPollBloc] and no
  /// poll shows.
  final EventPollState? poll;
  final void Function(BuildContext context)? onWhoAnswered;

  @override
  Widget build(BuildContext context) {
    final snapshot = state.detail.snapshot;
    final event = snapshot.event;
    return EventDatesSection(
      occurrences: snapshot.occurrences,
      schedulingMode: event.schedulingMode,
      now: now,
      actionsFor: hasActions
          ? (occurrence) => dateActionsFor(event, occurrence, state.actions)
          : null,
      onAdd:
          hasActions && canAddDate(event, snapshot.occurrences, state.actions)
          ? () => unawaited(
              _send(context, EventAction.addDate, () => _askAdd(context)),
            )
          : null,
      onAction: hasActions
          ? (occurrence, action) => unawaited(
              _send(context, action, () => _ask(context, occurrence, action)),
            )
          : null,
      poll: _pollView(context),
      enabled: enabled,
    );
  }

  /// The poll on the dates (#507), or null where none shows: no poll bloc,
  /// or no poll the server can be asked about, by the check the reads use.
  DatesPollView? _pollView(BuildContext context) {
    final poll = this.poll;
    if (poll == null || !_pollShows(state)) return null;

    final event = state.detail.snapshot.event;
    final onWhoAnswered = this.onWhoAnswered;
    return datesPollView(
      snapshot: state.detail.snapshot,
      viewer: state.detail.attendance,
      actions: state.actions,
      poll: poll,
      acting: acting,
      // Sent at once: no read can overwrite a vote, since the summary
      // isn't cached.
      onVote: (occurrence, response) => context.read<EventPollBloc>().add(
        EventPollVoted(event.id, occurrence.id, response),
      ),
      onRetry: () =>
          context.read<EventPollBloc>().add(EventPollRetryRequested(event.id)),
      onWhoAnswered: onWhoAnswered == null
          ? null
          : () => onWhoAnswered(context),
    );
  }

  /// Asks through [ask]'s dialog, then sends the request it answers for
  /// [action], as Delete does.
  Future<void> _send(
    BuildContext context,
    EventAction action,
    Future<_DateRequest?> Function() ask,
  ) async {
    // Read before the dialog opens: the page under it can rebuild without
    // these dates, and take the context they were asked from with it.
    final actions = context.read<EventActionsBloc>();
    final detail = context.read<EventDetailBloc>();
    final request = await ask();
    if (request == null || actions.isClosed) return;

    // A read can have started while the dialog was open, and the write
    // waits for it to end (#589). The event is the detail's as it is then,
    // whose id a reconcile can have moved (#499).
    final state = await _readEnded(detail);
    if (state is! EventDetailReady || actions.isClosed) return;

    // A sync can have cancelled the event while the dialog was open, and
    // the server still takes an edit or a removal on a cancelled event
    // (backend#956). Or taken the action from the viewer, and the server
    // still takes a confirm, decline or cancel from an organizer
    // (backend#979). The page already shows either, without the control.
    // A date's own change goes on to the server, whose 400 says so.
    final shown = state.detail.snapshot;
    if (!takesDateWrites(shown.event) || !state.actions.contains(action)) {
      return;
    }
    actions.add(request(shown));
  }

  Future<_DateRequest?> _askAdd(BuildContext context) async {
    final draft = await showAddDateDialog(context, now: now);
    if (draft == null) return null;
    // After the event's last date, as the dates stand once it is sent.
    return (shown) => EventDateAddRequested(
      shown.event.id,
      draft,
      sortOrder: nextSortOrder(shown.occurrences),
    );
  }

  Future<_DateRequest?> _ask(
    BuildContext context,
    EventOccurrence occurrence,
    EventAction action,
  ) async {
    final name = eventDateName(context, occurrence, now: now());
    final id = occurrence.id;

    switch (action) {
      case EventAction.editDate:
        final update = await showEditDateDialog(context, occurrence, now: now);
        if (update == null) return null;
        return (shown) => EventDateEditRequested(shown.event.id, id, update);
      case EventAction.confirmDate:
        final confirm = await showConfirmDateDialog(
          context,
          name,
          offerDeclineOthers: _offersDeclineOthers(occurrence),
        );
        if (confirm == null) return null;
        // The others as the event stands once it is sent (#507).
        return (shown) => EventDateConfirmRequested(
          shown.event.id,
          id,
          decline: confirm.declineOthers
              ? _otherProposed(shown.occurrences, id)
              : const [],
        );
      case EventAction.declineDate:
        if (!await showDeclineDateDialog(context, name)) return null;
        return (shown) => EventDateDeclineRequested(shown.event.id, id);
      case EventAction.cancelDate:
        final reason = await showCancelDateDialog(
          context,
          name,
          removing: false,
        );
        if (reason == null) return null;
        return (shown) =>
            EventDateCancelRequested(shown.event.id, id, reason: reason);
      // The server removes a Confirmed date only once it is cancelled
      // (#446), so one dialog asks for both, and its reason goes with the
      // cancel.
      case EventAction.removeDate
          when occurrence.status == OccurrenceStatus.confirmed:
        final reason = await showCancelDateDialog(
          context,
          name,
          removing: true,
        );
        if (reason == null) return null;
        return (shown) => EventDateRemoveRequested(
          shown.event.id,
          id,
          cancelFirst: true,
          reason: reason,
        );
      case EventAction.removeDate:
        if (!await showRemoveDateDialog(context, name)) return null;
        return (shown) => EventDateRemoveRequested(shown.event.id, id);
      // A date's menu offers only the date actions above.
      default:
        return null;
    }
  }

  /// Whether confirming [occurrence] offers to decline the event's other
  /// proposed dates in the same step (#507): on a poll that has another, to
  /// a viewer who may decline them.
  bool _offersDeclineOthers(EventOccurrence occurrence) {
    final snapshot = state.detail.snapshot;
    return snapshot.event.schedulingMode == EventSchedulingMode.poll &&
        state.actions.contains(EventAction.declineDate) &&
        _otherProposed(snapshot.occurrences, occurrence.id).isNotEmpty;
  }
}

/// The ids of [occurrences]' proposed dates other than [id], in order.
List<String> _otherProposed(List<EventOccurrence> occurrences, String id) => [
  for (final occurrence in occurrences)
    if (occurrence.id != id && occurrence.status == OccurrenceStatus.proposed)
      occurrence.id,
];

/// [detail]'s state once no read is running: now, or when the running one
/// ends. Its last state if it closes first. A write asked for through a
/// dialog waits on it, Delete's and the dates' alike.
Future<EventDetailState> _readEnded(EventDetailBloc detail) {
  bool ended(EventDetailState state) =>
      state is! EventDetailReady || !state.reading;

  if (ended(detail.state)) return Future.value(detail.state);
  return detail.stream.firstWhere(ended, orElse: () => detail.state);
}

/// A date's request, built from the event as the detail shows it once the
/// dialog closes.
typedef _DateRequest = EventActionsEvent Function(EventSnapshot shown);

/// How the last action went (#501, #506), or the last vote (#507), over the
/// event until dismissed or replaced. A live region, as every
/// [BgeInlineBanner] is. A delete's done has none: the screen leaves. Nor
/// does a vote's: its chip shows it.
class _ActionOutcomeBanner extends StatelessWidget {
  const _ActionOutcomeBanner({
    required this.outcome,
    required this.onDismiss,
    required this.bannerKey,
  });

  final EventActionOutcome outcome;

  /// Clears the outcome from the bloc that holds it.
  final VoidCallback onDismiss;

  /// The screen's key for this banner, on the [BgeInlineBanner] itself.
  final Key bannerKey;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final action = outcome.action;

    return BgeInlineBanner(
      key: bannerKey,
      tone: switch (outcome.result) {
        EventActionResult.done => BgeBannerTone.success,
        // Gone is what deleting and removing a date asked for: a second
        // press after an answer was lost finds it so. Any other date write's
        // is the date it named gone from under it.
        EventActionResult.gone =>
          action == EventAction.delete || action == EventAction.removeDate
              ? BgeBannerTone.success
              : BgeBannerTone.warning,
        EventActionResult.refused ||
        EventActionResult.changed ||
        EventActionResult.partlyDone => BgeBannerTone.warning,
        EventActionResult.failed => BgeBannerTone.error,
      },
      message: switch (outcome.action) {
        EventAction.addDate => _dateMessage(l10n, done: l10n.eventsDateAdded),
        EventAction.editDate => _dateMessage(l10n, done: l10n.eventsDateSaved),
        EventAction.confirmDate => _dateMessage(
          l10n,
          done: l10n.eventsDateConfirmed,
        ),
        EventAction.declineDate => _dateMessage(
          l10n,
          done: l10n.eventsDateDeclined,
        ),
        EventAction.cancelDate => _dateMessage(
          l10n,
          done: l10n.eventsDateCancelled,
        ),
        EventAction.removeDate => _dateMessage(
          l10n,
          done: l10n.eventsDateRemoved,
        ),
        EventAction.voteAvailability => _voteMessage(l10n),
        // Delete is the only other action the screen sends yet. #500's and
        // #502's add their own copy.
        _ => _deleteMessage(l10n),
      },
      action: TextButton(
        onPressed: onDismiss,
        child: Text(l10n.eventsActionDismiss),
      ),
    );
  }

  /// A vote's copy (#507). A failure never says the answer wasn't saved:
  /// one whose answer was lost may have landed.
  String _voteMessage(EventsLocalizations l10n) => switch (outcome.result) {
    EventActionResult.changed => l10n.eventsPollVoteChanged,
    EventActionResult.gone => l10n.eventsDateGone,
    EventActionResult.refused => l10n.eventsPollVoteRefused,
    // Done and partly done never come here: done shows on the chip, and a
    // vote is one request.
    EventActionResult.failed ||
    EventActionResult.done ||
    EventActionResult.partlyDone => l10n.eventsPollVoteFailed,
  };

  String _deleteMessage(EventsLocalizations l10n) => switch (outcome.result) {
    EventActionResult.done => l10n.eventsDeleted,
    EventActionResult.gone => l10n.eventsDeleteGone,
    EventActionResult.refused => l10n.eventsDeleteRefused,
    // Only a date write (#506) ends changed or partlyDone.
    EventActionResult.changed => l10n.eventsDateChanged,
    EventActionResult.partlyDone => l10n.eventsDateCancelledRemoveUnconfirmed,
    // Only a transient failure is worth pressing again (#501). A session
    // that moved and a cache that couldn't be read sent nothing, and a 4xx
    // was refused: the same press would end the same way.
    EventActionResult.failed =>
      outcome.error is EventRemoteTransientException
          ? l10n.eventsDeleteFailed
          : l10n.eventsDeleteFailedUnexpected,
  };

  /// A date write's copy (#506), saying [done] where it was.
  ///
  /// A failure never says the change didn't happen: a write whose answer
  /// was lost may have landed. An add that went out is read again before
  /// Add can be pressed twice, since a second add is a second date
  /// (backend#902), so it asks the user to look first. Any other failure
  /// that was transient may be pressed again. One that wasn't, or that sent
  /// nothing, would end the same way.
  String _dateMessage(EventsLocalizations l10n, {required String done}) =>
      switch (outcome.result) {
        EventActionResult.done => done,
        EventActionResult.gone => l10n.eventsDateGone,
        EventActionResult.refused => l10n.eventsDateRefused,
        EventActionResult.changed => l10n.eventsDateChanged,
        // A confirm whose declines didn't all land (#507), or a cancel whose
        // remove didn't (#446).
        EventActionResult.partlyDone =>
          outcome.action == EventAction.confirmDate
              ? l10n.eventsDateConfirmedNotAllDeclined
              : l10n.eventsDateCancelledRemoveUnconfirmed,
        EventActionResult.failed =>
          outcome.action == EventAction.addDate && outcome.error != null
              ? l10n.eventsDateAddFailed
              : outcome.error is EventRemoteTransientException
              ? l10n.eventsDateFailed
              : l10n.eventsDateFailedUnexpected,
      };
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
