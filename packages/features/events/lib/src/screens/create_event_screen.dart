import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:user_search/user_search.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/create_event_bloc.dart';
import '../bloc/create_event_event.dart';
import '../bloc/create_event_state.dart';
import '../create/create_event_form.dart';
import '../create/event_create_households.dart';

/// The screen for creating an event (#499): what it is, when it happens,
/// who it invites and its rules, written on this device and sent straight
/// away.
///
/// Decoupled from DI like the other screens: the caller resolves the
/// [repository], [sender] and [users] from the active server's scope, and
/// passes the households an event may join where it has them. The screen
/// provides the [CreateEventBloc] and the [UserSearchBloc] itself.
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
/// The invitee search is the shared user search, so the caller registers
/// `UserSearchLocalizations`' delegate beside this package's.
class CreateEventScreen extends StatelessWidget {
  const CreateEventScreen({
    required this.repository,
    required this.sender,
    required this.users,
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

  /// Where the created event is shown. Called once, with the event's id:
  /// the server's when the send was delivered, the local one when it stayed
  /// queued.
  ///
  /// Required, as the household create's is: a create with nowhere to go
  /// leaves the user on the spent form (#162).
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
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => CreateEventBloc(
            repository: repository,
            sender: sender,
            onRefresh: onRefresh,
          ),
        ),
        BlocProvider(create: (_) => UserSearchBloc(remote: users)),
      ],
      child: _CreateEventView(
        onCreated: onCreated,
        households: households,
        householdId: householdId,
        now: now,
      ),
    );
  }
}

class _CreateEventView extends StatelessWidget {
  const _CreateEventView({
    required this.onCreated,
    this.households,
    this.householdId,
    this.now,
  });

  final void Function(BuildContext context, String eventId) onCreated;
  final Stream<List<Household>>? households;
  final String? householdId;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);

    return BlocConsumer<CreateEventBloc, CreateEventState>(
      // Success only: a refusal or a failure is a banner the form draws.
      listenWhen: (_, state) => state is CreateEventSuccess,
      listener: (context, state) {
        if (state case CreateEventSuccess(:final eventId, :final sync)) {
          // A SnackBar, which outlives the route `onCreated` takes the user
          // off, and is already a live region (#191).
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(switch (sync) {
                CreateEventSync.synced => l10n.eventCreateSynced,
                // Also a refused create another tab retried or discarded
                // since. After a discard its local id names nothing, and
                // the detail says so (see CreateEventSuccess).
                CreateEventSync.queued => l10n.eventCreateQueued,
              }),
            ),
          );
          // Shown first, then handed on, while this route's context is
          // still current. No `maybePop`: where the event is shown is the
          // caller's to decide (#162).
          onCreated(context, eventId);
        }
      },
      builder: (context, state) => BgePage(
        title: Text(l10n.eventCreateTitle),
        width: BgePageWidth.form,
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
