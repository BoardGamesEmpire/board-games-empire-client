import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/create_event_bloc.dart';
import 'package:events/src/bloc/create_event_event.dart';
import 'package:events/src/bloc/create_event_state.dart';
import 'package:events/src/create/create_event_form.dart';
import 'package:events/src/create/event_create_households.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:user_search/user_search.dart';

/// The screen for creating an event (#499): what it is, when it happens,
/// who it invites and its rules, written on this device and sent straight
/// away.
///
/// Decoupled from DI like the other screens: the caller resolves the
/// [repository], [sender] and [users] from the active server's scope, and
/// passes the households an event may join where it has them. The screen
/// makes the [CreateEventBloc] and provides the [UserSearchBloc] itself.
///
/// The outcomes use different surfaces, as the household create's do
/// (#191):
///
/// - A success takes the user off the form, so it says so in a SnackBar,
///   which outlives the route, then hands the event to [onCreated].
/// - A refusal or a failure keeps the user on the form, so it is a banner
///   directly above the submit it answers, until the next edit takes it
///   down. Its heading says the event wasn't created, and its message why
///   (#211). A refusal names the invitee the server refused, when it says
///   which, or the household, when the create was in one and invited no
///   one. The refused create stays parked until the next submit discards it.
///
/// The screen holds its create's bloc, not a `BlocProvider`, so a create the
/// user walks away from still ends (#464). Left while one is on its way, the
/// bloc is kept until it settles, its outcome is said in a SnackBar over the
/// page the user went to (a failure too, in its banner's heading, since the
/// banner went with the form, and a refusal by where to review it), and then
/// it closes, through `closeWhenSettled`. One that settles while the route is
/// still on its way out is said the same way. That late outcome never calls
/// [onCreated]: the user has already gone somewhere. No outcome is said once
/// [session] has ended, whether the screen is gone or still leaving: it is
/// no news to whoever signs in next (#694). The bloc closes either way.
///
/// The invitee search is the shared user search, so the caller registers
/// `UserSearchLocalizations`' delegate beside this package's.
class CreateEventScreen extends StatefulWidget {
  const CreateEventScreen({
    required this.repository,
    required this.sender,
    required this.users,
    required this.session,
    required this.onCreated,
    this.households,
    this.householdId,
    this.onRefresh,
    this.now,
    super.key,
  });

  static const Key titleKey = Key('event_create.title');
  static const Key householdKey = Key('event_create.household');
  static const Key typeKey = Key('event_create.type');
  static const Key reachKey = Key('event_create.reach');
  static const Key descriptionKey = Key('event_create.description');
  static const Key locationKey = Key('event_create.location');
  static const Key urlKey = Key('event_create.url');
  static const Key submitKey = Key('event_create.submit');

  /// Key on the banner saying the server refused the create.
  static const Key refusedKey = Key('event_create.refused');

  /// Key on the banner saying the create failed on this device.
  static const Key errorKey = Key('event_create.error');

  /// The user-session event repository the create is written to.
  final EventRepository repository;

  /// The inline send's delivery path, shared with the queue drain. It
  /// claims the queued create first, so the two can't both deliver it.
  final SyncOperationSender sender;

  /// What *Who's invited* searches for people through.
  final UserRemoteDataSource users;

  /// The user session this screen was opened in, from the same container as
  /// [repository] and [sender]. A create that settles after the screen is
  /// gone is said only while it is live (#694).
  final SessionLease session;

  /// Where the created event is shown. Called once, with the event's id:
  /// the server's when the send was delivered, the local one when it stayed
  /// queued.
  ///
  /// Required, as the household create's is: a create with nowhere to go
  /// leaves the user on the spent form (#162). Not called for a create that
  /// lands once the user has left (#464).
  final void Function(BuildContext context, String eventId) onCreated;

  /// The households an event may join, as [eventCreateHouseholds] filters
  /// them. Null where there are none to read, which leaves the household
  /// picker out, so the event joins no household.
  ///
  /// Read once, when the screen is built.
  final Stream<List<Household>>? households;

  /// The household to start in, as a link to the form names it.
  ///
  /// Picked from the first list [households] emits that offers it, unless
  /// the user picked a household or submitted first. Until then the event
  /// joins no household, so one the user may not create in, or one the
  /// server doesn't know, is never sent.
  final String? householdId;

  /// Reads the user's households again, or null where there is no way to.
  /// Started after the server refuses a create in a household with 403, so
  /// [households] stops offering one the user may no longer create in.
  final Future<void> Function()? onRefresh;

  /// The clock the date pickers open on and count from. Defaults to the
  /// device's.
  final DateTime Function()? now;

  @override
  State<CreateEventScreen> createState() => _CreateEventScreenState();
}

class _CreateEventScreenState extends State<CreateEventScreen> {
  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the route: a create still on its way then would never say how it ended.
  /// See [dispose].
  late final CreateEventBloc _bloc;

  /// The lease [widget] had when the bloc was made, beside the repository it
  /// came from: [dispose] can't trust a later build's.
  late final SessionLease _session;

  /// The messenger above the route, which says a bar only while [_session] is
  /// live, and this screen's strings, captured while the screen is mounted: a
  /// create that settles after it is gone is said with them, and [dispose]
  /// can't look them up.
  late final SessionMessenger _messenger = SessionMessenger(
    sessionIsLive: () => _session.isLive,
  );
  late EventsLocalizations _l10n;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _bloc = CreateEventBloc(
      repository: widget.repository,
      sender: widget.sender,
      onRefresh: widget.onRefresh,
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
    // Left with a create on its way: it settles, is said while the session
    // lives, and the bloc closes then. Otherwise the screen has already
    // shown whatever there was, and the bloc closes now.
    unawaited(
      closeWhenSettled<CreateEventState>(
        current: _bloc.state,
        states: _bloc.stream,
        underWay: (state) => state is CreateEventSubmitting,
        outcomeOf: _lateOutcome,
        say: _messenger.say,
        close: _bloc.close,
      ),
    );
    super.dispose();
  }

  /// What is said of a create that settled after the screen went, or while
  /// it was going (#464): a success as the listener says it, and a failure
  /// in its banner's heading, since the banner went with the form.
  ///
  /// A refusal says more than the heading. Its create stays parked with its
  /// local-only event, and with the form gone no next submit will discard
  /// them, so it sends the user to the home screen's review list (#190).
  String? _lateOutcome(CreateEventState state) => switch (state) {
    CreateEventSuccess(:final sync) => _createdMessage(_l10n, sync),
    CreateEventRefused() => _l10n.eventCreateRefusedLate,
    CreateEventFailure() => _l10n.eventCreateFailedTitle,
    CreateEventInitial() || CreateEventSubmitting() => null,
  };

  /// Answers a create that has just ended.
  void _onEnded(BuildContext context, CreateEventState state) {
    // Popped or removed, and mounted only for its exit: the user has left,
    // so the outcome is said as it would be once the form had gone, a
    // refusal or a failure too, and [CreateEventScreen.onCreated] is not
    // called (#464). By [dispose] it has settled, so `closeWhenSettled` says
    // nothing more.
    if (ModalRoute.isActiveOf(context) == false) {
      _messenger.say(_lateOutcome(state));
      return;
    }
    // A refusal or a failure stays: the form draws it as a banner.
    if (state case CreateEventSuccess(:final eventId, :final sync)) {
      // A SnackBar, which outlives the route `onCreated` takes the user off,
      // and is already a live region (#191).
      _messenger.say(_createdMessage(_l10n, sync));
      // Shown first, then handed on, while this route's context is still
      // current. No `maybePop`: where the event is shown is the caller's to
      // decide (#162).
      widget.onCreated(context, eventId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<CreateEventBloc>.value(value: _bloc),
        BlocProvider(create: (_) => UserSearchBloc(remote: widget.users)),
      ],
      child: BlocListener<CreateEventBloc, CreateEventState>(
        listenWhen: (_, state) =>
            state is CreateEventSuccess ||
            state is CreateEventRefused ||
            state is CreateEventFailure,
        listener: _onEnded,
        child: _CreateEventView(
          households: widget.households,
          householdId: widget.householdId,
          now: widget.now,
        ),
      ),
    );
  }
}

/// What the SnackBar says once a create has succeeded: whether the server
/// has the event. Said by the listener as the form goes, or as a late
/// outcome for a create that lands once the user has left (#464).
String _createdMessage(EventsLocalizations l10n, CreateEventSync sync) =>
    switch (sync) {
      CreateEventSync.synced => l10n.eventCreateSynced,
      // Also a refused create another tab retried or discarded since. After
      // a discard its local id names nothing, and the detail says so (see
      // CreateEventSuccess).
      CreateEventSync.queued => l10n.eventCreateQueued,
    };

class _CreateEventView extends StatelessWidget {
  const _CreateEventView({this.households, this.householdId, this.now});

  final Stream<List<Household>>? households;
  final String? householdId;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return BlocBuilder<CreateEventBloc, CreateEventState>(
      builder: (context, state) => BgePage(
        title: Text(l10n.eventCreateTitle),
        child: CreateEventForm(
          state: state,
          households: households,
          householdId: householdId,
          now: now,
          onSubmit: (draft) =>
              context.read<CreateEventBloc>().add(CreateEventSubmitted(draft)),
          onEdited: () => context.read<CreateEventBloc>().add(
            const CreateEventFailureCleared(),
          ),
        ),
      ),
    );
  }
}
