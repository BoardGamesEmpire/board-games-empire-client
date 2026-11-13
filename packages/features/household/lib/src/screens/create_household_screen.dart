import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:household/src/bloc/create_household_bloc.dart';
import 'package:household/src/bloc/create_household_event.dart';
import 'package:household/src/bloc/create_household_state.dart';
import 'package:household/src/widgets/create_household_form.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:ui/ui.dart';

/// Screen for creating a household (#40).
///
/// Decoupled from DI: the caller (router / app shell) resolves the
/// [HouseholdRepository] and [SyncOperationSender] from the active server
/// scope and passes them in; the screen makes the [CreateHouseholdBloc]
/// itself. On success it shows a confirmation (synced vs. still-queued) and
/// reports the new household to [onCreated]; on an unexpected local failure
/// it shows an error and stays put.
///
/// The two outcomes use different surfaces on purpose (#191). Success takes
/// the user off this screen, so its confirmation has to outlive the route —
/// that is a SnackBar, owned by the ScaffoldMessenger above it. Failure stays
/// put, so it belongs on the screen: a banner directly above the submit it
/// answers, rendered by the form (#211).
///
/// The screen holds its bloc, not a `BlocProvider`, so a create the user
/// walks away from still ends (#464). Left while one is under way, the bloc
/// is kept until it settles, its outcome is said in a SnackBar over the page
/// the user went to (a failure too, since its banner went with the form),
/// and then it closes, through `closeWhenSettled`. One that settles while the
/// route is still on its way out is said the same way. That late outcome
/// never calls [onCreated]: the user has already gone somewhere. No outcome
/// is said once [session] has ended, whether the screen is gone or still
/// leaving: it is no news to whoever signs in next (#694). The bloc closes
/// either way.
class CreateHouseholdScreen extends StatefulWidget {
  const CreateHouseholdScreen({
    required this.repository,
    required this.sender,
    required this.session,
    required this.onCreated,
    super.key,
  });

  /// Key on the create-failure banner, for tests.
  static const Key errorBannerKey = Key('create_household.error_banner');

  final HouseholdRepository repository;

  /// The inline send's delivery path, shared with the queue drain (#121).
  /// It claims the queued op first (#430), so the two can't both deliver
  /// one create.
  final SyncOperationSender sender;

  /// The user session this screen was opened in, from the same container as
  /// [repository] and [sender]. A create that settles after the screen is
  /// gone is said only while it is live (#694).
  final SessionLease session;

  /// Where the created household is shown (#271). Called once, with the id
  /// the household now has: the canonical one when the inline sync
  /// confirmed it, the optimistic local one when it stayed queued.
  ///
  /// **Required**, unlike the list screen's `onCreate` / `onOpen` and the
  /// detail screen's `onBack` (#271 D2). Those degrade to something coherent
  /// when absent — an inert row, a screen with no back button. A successful
  /// create with nowhere to go does not: it is #162, the user left staring
  /// at the form that just succeeded. The screen therefore cannot be built
  /// without an answer, and there is no pop fallback to hide a missing one.
  final void Function(BuildContext context, String householdId) onCreated;

  @override
  State<CreateHouseholdScreen> createState() => _CreateHouseholdScreenState();
}

class _CreateHouseholdScreenState extends State<CreateHouseholdScreen> {
  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the route: a create still under way then would never say how it ended.
  /// See [dispose].
  late final CreateHouseholdBloc _bloc;

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
  late HouseholdLocalizations _l10n;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _bloc = CreateHouseholdBloc(
      repository: widget.repository,
      sender: widget.sender,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger.attach(context);
    _l10n = HouseholdLocalizations.of(context);
  }

  @override
  void dispose() {
    // Left with a create under way: it settles, is said while the session
    // lives, and the bloc closes then. Otherwise the screen has already
    // shown whatever there was, and the bloc closes now.
    unawaited(
      closeWhenSettled<CreateHouseholdState>(
        current: _bloc.state,
        states: _bloc.stream,
        underWay: (state) => state is CreateHouseholdSubmitting,
        outcomeOf: _lateOutcome,
        say: _messenger.say,
        close: _bloc.close,
      ),
    );
    super.dispose();
  }

  /// What is said of a create that settled after the screen went, or while
  /// it was going (#464): a success as the listener says it, and a failure,
  /// whose banner went with the form, in the banner's words.
  String? _lateOutcome(CreateHouseholdState state) => switch (state) {
    CreateHouseholdSuccess(:final sync) => _createdMessage(_l10n, sync),
    CreateHouseholdFailure() => _l10n.createHouseholdError,
    CreateHouseholdInitial() || CreateHouseholdSubmitting() => null,
  };

  /// Answers a create that has just ended.
  void _onEnded(BuildContext context, CreateHouseholdState state) {
    // Popped or removed, and mounted only for its exit: the user has left,
    // so the outcome is said as it would be once the form had gone, a
    // failure too, and [CreateHouseholdScreen.onCreated] is not called
    // (#464). By [dispose] it has settled, so `closeWhenSettled` says nothing
    // more.
    if (ModalRoute.isActiveOf(context) == false) {
      _messenger.say(_lateOutcome(state));
      return;
    }
    // A failure stays: the form draws it as a banner.
    if (state case CreateHouseholdSuccess(:final householdId, :final sync)) {
      // Deliberately a SnackBar: the next line takes this screen off the
      // stack, so an inline banner would be destroyed before it could be
      // read. The ScaffoldMessenger outlives the route. No
      // `Semantics(liveRegion:)` wrapper — SnackBar already is one
      // (`snack_bar.dart`), and nesting them makes screen readers stutter
      // (#191).
      _messenger.say(_createdMessage(_l10n, sync));
      // Shown first, navigated second, and in that order: the messenger has
      // to receive the SnackBar while this route's context is still current.
      //
      // No `maybePop` (#271). The old pop-with-id is what #162 was: on a
      // root route it no-opped and left the user on the spent form. Handing
      // the id upward instead means the caller decides where to go, and can
      // do it with a replace that has no such failure mode.
      widget.onCreated(context, householdId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<CreateHouseholdBloc>.value(
      value: _bloc,
      child: BlocListener<CreateHouseholdBloc, CreateHouseholdState>(
        listenWhen: (_, state) =>
            state is CreateHouseholdSuccess || state is CreateHouseholdFailure,
        listener: _onEnded,
        child: const _CreateHouseholdView(),
      ),
    );
  }
}

/// What the SnackBar says once a create has succeeded: whether the server
/// has the household. Said by the listener as the form goes, or as a late
/// outcome for a create that lands once the user has left (#464).
String _createdMessage(
  HouseholdLocalizations l10n,
  CreateHouseholdSync sync,
) => switch (sync) {
  CreateHouseholdSync.synced => l10n.createHouseholdSynced,
  CreateHouseholdSync.queued => l10n.createHouseholdQueued,
  // No later sync sends it, so say where the user can retry or discard it
  // instead (#190).
  CreateHouseholdSync.refused => l10n.createHouseholdRefused,
};

class _CreateHouseholdView extends StatelessWidget {
  const _CreateHouseholdView();

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    return BlocBuilder<CreateHouseholdBloc, CreateHouseholdState>(
      builder: (context, state) {
        final submitting = state is CreateHouseholdSubmitting;
        return BgePage(
          title: Text(l10n.createHouseholdTitle),
          child: CreateHouseholdForm(
            submitting: submitting,
            failure: state is CreateHouseholdFailure
                ? BgeFormFailure(
                    key: CreateHouseholdScreen.errorBannerKey,
                    // Untitled: its one message already names the operation
                    // ("…creating your household"), and a heading would say
                    // it twice (#211).
                    title: null,
                    message: l10n.createHouseholdError,
                  )
                : null,
            // Retire the banner as soon as the user edits: it describes the
            // value they are replacing, and being bound to bloc state it does
            // not fade the way a SnackBar would (#191).
            onEdited: () => context.read<CreateHouseholdBloc>().add(
              const CreateHouseholdFailureCleared(),
            ),
            onSubmit: ({required name, description}) =>
                context.read<CreateHouseholdBloc>().add(
                  CreateHouseholdSubmitted(
                    name: name,
                    description: description,
                  ),
                ),
          ),
        );
      },
    );
  }
}
