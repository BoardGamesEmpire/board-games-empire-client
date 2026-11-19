import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/edit_event_bloc.dart';
import 'package:events/src/bloc/edit_event_event.dart';
import 'package:events/src/bloc/edit_event_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/edit/edit_event_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart' hide ConnectionState;
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart';

/// The page for editing an event's details and its rules (#500), beneath
/// the event's screen.
///
/// A save is a direct write, as the household edit's is (#476): it goes
/// straight to the server and its answer is cached, so nothing waits in the
/// sync queue, and Save is disabled offline. The page itself opens offline,
/// from the cache.
///
/// ## Opening
///
/// It reads the event once, from the cache's first answer, with the
/// viewer's role on it and, on a household event, in its household, and
/// works out what they may do from those. A later change to the cache
/// never fills the form again, so nothing typed is replaced. Opened from a
/// detail that followed a reconcile (#499), the route still carries the
/// event's local id, so the event is read by the id it moved to.
///
/// - An event this device doesn't hold, or can't read, says so, with a way
///   back.
/// - A viewer who may not edit the event is told so, with a way back: they
///   can arrive from a link, or after their role changed.
/// - A viewer who may edit the event but not its rules sees the rules
///   read-only ([EditEventForm]).
///
/// ## The outcomes
///
/// They use different surfaces, as the household edit's do (#191):
///
/// - A save takes the user off the page, so it says so in a SnackBar, which
///   outlives the route, then calls [onLeave]. A save that changed nothing
///   sent nothing, and says nothing.
/// - A save of an event the server no longer has leaves the page without a
///   word: the event's screen, read again, says it is gone (#498).
/// - Any other failure keeps the user on the page, in a banner directly
///   above Save, until the next edit takes it down. Its heading says what
///   wasn't saved: nothing, or the rules alone when the details were saved
///   first.
///
/// The page holds its bloc, not a `BlocProvider`, so a save the user walks
/// away from still ends (#464). Left while one is on its way, the bloc is
/// kept until it settles, its outcome is said in a SnackBar over the page
/// the user went to (a failure by its banner's heading, since the banner
/// went with the page), and then it closes, through `closeWhenSettled`. One
/// that settles while the route is still on its way out is said the same
/// way. That late outcome never calls [onLeave]: the user has already gone
/// somewhere. No outcome is said once [session] has ended, whether the page
/// is gone or still leaving: it is no news to whoever signs in next (#694).
/// The bloc closes either way.
///
/// Decoupled from DI like the other screens: the caller resolves the
/// [repository] and the per-server [remote], and leaves the page in
/// [onLeave].
class EditEventScreen extends StatelessWidget {
  const EditEventScreen({
    required this.eventId,
    required this.repository,
    required this.remote,
    required this.session,
    required this.onLeave,
    this.confirmSession,
    this.householdRole,
    super.key,
  });

  /// Key on Save.
  static const Key saveKey = Key('event_edit.save');

  /// Key on what shows in place of the form for a viewer who may not edit
  /// the event.
  static const Key notAllowedKey = Key('event_edit.not_allowed');

  /// Key on what shows in place of the form for an event this device
  /// doesn't hold.
  static const Key notCachedKey = Key('event_edit.not_cached');

  /// Key on the line saying why the rules can't be shown, in their place.
  static const Key rulesNoteKey = Key('event_edit.rules_note');

  /// Key on the banner of a save that failed, above Save.
  static const Key failureKey = Key('event_edit.failure');

  /// The event to edit.
  final String eventId;

  /// The user-session event repository the event is read from, and each
  /// saved answer written to.
  final EventRepository repository;

  /// The per-server event client the edit is sent through.
  final EventRemoteDataSource remote;

  /// The user session this page was opened in, from the same container as
  /// [repository] and [remote]. A save that settles after the page is gone
  /// is said only while it is live (#694).
  final SessionLease session;

  /// Whether the session is still the user [repository] belongs to, asked
  /// before an edit goes out (#432). Null, as on native, is always yes.
  final Future<bool> Function()? confirmSession;

  /// The viewer's role in a household, for what they may do to its events
  /// without attending. Asked once, on a household event. Null, or a lookup
  /// that fails, gives household roles no say.
  final Future<HouseholdRole?> Function(String householdId)? householdRole;

  /// Leaves the page, with its context: once an edit is saved, when the
  /// event is gone, and from the way back where there is no form. Called
  /// once. A confirmation SnackBar is already showing when an edit was
  /// saved, unless it changed nothing. Not called for a save that lands
  /// once the user has left the page (#464). The feature package doesn't
  /// know the route table.
  final void Function(BuildContext context) onLeave;

  @override
  Widget build(BuildContext context) => _EditEventOpening(
    // A new event is a new read, and a new form.
    key: ValueKey<String>(eventId),
    screen: this,
  );
}

/// What the page opened with: the event as the cache held it, and what the
/// viewer may do to it.
typedef _Opened = ({EventDetail detail, Set<EventAction> actions});

class _EditEventOpening extends StatefulWidget {
  const _EditEventOpening({required this.screen, super.key});

  final EditEventScreen screen;

  @override
  State<_EditEventOpening> createState() => _EditEventOpeningState();
}

class _EditEventOpeningState extends State<_EditEventOpening> {
  final BgeLogger _logger = BgeLogger('bge.events.edit');

  /// The one read the page makes. Null when the cache holds no such event
  /// for this user, or couldn't be read, or the page closed before it
  /// answered.
  late final Future<_Opened?> _opened = _open();

  Future<_Opened?> _open() async {
    final screen = widget.screen;
    final repository = screen.repository;
    final eventId =
        repository.reconciledEventId(screen.eventId) ?? screen.eventId;
    final EventDetail? detail;
    try {
      detail = await repository.watchEvent(eventId).first;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Event edit could not read the event from the cache',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
    // A page closed while the cache answered shows nothing, so it asks
    // nothing more.
    if (detail == null || !mounted) return null;

    final event = detail.snapshot.event;
    final householdId = event.householdId;
    return (
      detail: detail,
      actions: eventActionsFor(
        event,
        eventRole: detail.attendance?.role,
        householdRole: householdId == null
            ? null
            : await _householdRole(householdId),
      ),
    );
  }

  /// The viewer's role in [householdId], or null when there is no way to
  /// ask or the lookup fails.
  Future<HouseholdRole?> _householdRole(String householdId) async {
    final lookUp = widget.screen.householdRole;
    if (lookUp == null) return null;
    try {
      return await lookUp(householdId);
    } on Object catch (error, stackTrace) {
      // The household's say is lost, not the page.
      _logger.warn(
        'Event edit household role lookup failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final screen = widget.screen;
    return FutureBuilder<_Opened?>(
      future: _opened,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return BgePage(
            title: Text(l10n.eventEditTitle),
            centerVertically: true,
            child: BgeLoadingState(label: l10n.eventsDetailLoading),
          );
        }
        final opened = snapshot.data;
        if (opened == null) {
          return _Note(
            noteKey: EditEventScreen.notCachedKey,
            text: l10n.eventEditNotCached,
            onLeave: screen.onLeave,
          );
        }
        if (!opened.actions.contains(EventAction.edit)) {
          return _Note(
            noteKey: EditEventScreen.notAllowedKey,
            text: l10n.eventEditNotAllowed,
            onLeave: screen.onLeave,
          );
        }
        return _EditEventView(
          detail: opened.detail,
          editsRules: opened.actions.contains(EventAction.editRules),
          screen: screen,
        );
      },
    );
  }
}

/// Why there is no form, under the page's title, and the way back.
class _Note extends StatelessWidget {
  const _Note({
    required this.noteKey,
    required this.text,
    required this.onLeave,
  });

  final Key noteKey;
  final String text;
  final void Function(BuildContext context) onLeave;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    return BgePage(
      title: Text(l10n.eventEditTitle),
      centerVertically: true,
      child: BgeEmptyState(
        key: noteKey,
        title: text,
        // The app bar's back button does the same. This one is here
        // because leaving is all there is to do.
        action: FilledButton(
          onPressed: () => onLeave(context),
          child: Text(l10n.eventsOfferBack),
        ),
      ),
    );
  }
}

class _EditEventView extends StatefulWidget {
  const _EditEventView({
    required this.detail,
    required this.editsRules,
    required this.screen,
  });

  /// The event as the page opened with it. Read once, by the bloc and the
  /// form.
  final EventDetail detail;

  /// Whether the viewer may change the rules. Read once.
  final bool editsRules;

  final EditEventScreen screen;

  @override
  State<_EditEventView> createState() => _EditEventViewState();
}

class _EditEventViewState extends State<_EditEventView> {
  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the page: a save still on its way then would never say how it ended.
  /// See [dispose].
  late final EditEventBloc _bloc;

  /// The lease the screen had when the bloc was made, beside the repository
  /// and remote it came from: [dispose] can't trust a later build's.
  late final SessionLease _session;

  /// The messenger above the route, which says a bar only while [_session]
  /// is live, and this page's strings, captured while it is mounted: a save
  /// that settles after it is gone is said with them, and [dispose] can't
  /// look them up.
  late final SessionMessenger _messenger = SessionMessenger(
    sessionIsLive: () => _session.isLive,
  );
  late EventsLocalizations _l10n;

  /// Whether the page has left through [EditEventScreen.onLeave]. The route
  /// stays mounted through its exit, so nothing calls it again.
  bool _left = false;

  @override
  void initState() {
    super.initState();
    final screen = widget.screen;
    final snapshot = widget.detail.snapshot;
    _session = screen.session;
    _bloc = EditEventBloc(
      event: snapshot.event,
      policy: snapshot.policy,
      remote: screen.remote,
      repository: screen.repository,
      confirmSession: screen.confirmSession,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger.attach(context);
    _l10n = EventsLocalizations.of(context);
  }

  @override
  void dispose() {
    // Left with a save on its way: it settles, is said while the session
    // lives, and the bloc closes then. Otherwise the page has already shown
    // whatever there was, and the bloc closes now.
    unawaited(
      closeWhenSettled<EditEventState>(
        current: _bloc.state,
        states: _bloc.stream,
        underWay: (state) => state is EditEventSaving,
        outcomeOf: _lateOutcome,
        say: _messenger.say,
        close: _bloc.close,
      ),
    );
    super.dispose();
  }

  /// What is said of a save that settled after the page went, or while it
  /// was going (#464): a save as the listener says it, and a failure by its
  /// banner's heading, since the banner went with the page. Away from the
  /// page there is nothing to fix, so the reason is left out. An event the
  /// server no longer has is said the same way: this page can't take the
  /// user to the event's screen, which would say it is gone, so the bar is
  /// its only word.
  String? _lateOutcome(EditEventState state) => switch (state) {
    EditEventSaved() => _savedMessage(_l10n, state),
    final EditEventFailed failed => editEventFailureTitle(_l10n, failed),
    EditEventEditing() || EditEventSaving() => null,
  };

  /// Answers a save that has just ended.
  void _onEnded(BuildContext context, EditEventState state) {
    if (_left) return;
    // Popped or removed, and mounted only for its exit: the user has left,
    // so the outcome is said as it would be once the page had gone, a
    // failure too, and [EditEventScreen.onLeave] is not called (#464). By
    // [dispose] it has settled, so `closeWhenSettled` says nothing more.
    if (ModalRoute.isActiveOf(context) == false) {
      _messenger.say(_lateOutcome(state));
      return;
    }
    switch (state) {
      case EditEventSaved():
        // A SnackBar, since the next line takes this page away; the
        // messenger outlives the route, and its bar is already a live
        // region (#191).
        _leave(context, _savedMessage(_l10n, state));
      case EditEventFailed(reason: EditEventFailure.gone):
        // The event's screen, read again, says it is gone (#498).
        _leave(context, null);
      // Any other failure stays: the form draws it as a banner.
      case EditEventFailed() || EditEventEditing() || EditEventSaving():
        break;
    }
  }

  void _leave(BuildContext context, String? message) {
    _left = true;
    _messenger.say(message);
    widget.screen.onLeave(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final snapshot = widget.detail.snapshot;
    return BlocProvider<EditEventBloc>.value(
      value: _bloc,
      child: BlocConsumer<EditEventBloc, EditEventState>(
        listenWhen: (_, state) =>
            state is EditEventSaved || state is EditEventFailed,
        listener: _onEnded,
        builder: (context, state) => BgePage(
          title: Text(l10n.eventEditTitle),
          child: EditEventForm(
            event: snapshot.event,
            policy: snapshot.policy,
            editsRules: widget.editsRules,
            state: state,
            onSubmit: (values) => _bloc.add(EditEventSubmitted(values)),
            onEdited: () => _bloc.add(const EditEventEdited()),
          ),
        ),
      ),
    );
  }
}

/// What the SnackBar says once an edit is saved, or null for a save that
/// changed nothing: it sent nothing. Said by the listener as the page goes,
/// or as a late outcome for a save that lands once the user has left
/// (#464).
String? _savedMessage(EventsLocalizations l10n, EditEventSaved state) =>
    state.changed ? l10n.eventEditSaved : null;
