import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:household/src/bloc/edit_household_bloc.dart';
import 'package:household/src/bloc/edit_household_event.dart';
import 'package:household/src/bloc/edit_household_state.dart';
import 'package:household/src/permissions/household_actions.dart';
import 'package:household/src/widgets/edit_household_form.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

/// The screen for editing a household's name, description and member invite
/// policy (#476).
///
/// Online-only, like the invite screens: a save goes straight to the server
/// and its answer is cached, so nothing waits in the sync queue. A save
/// that cannot reach the server leaves the form as typed.
///
/// It reads the household and who is looking from the cache, and reads them
/// again whenever the household's roster changes, as the send-invite route
/// does. On a deep link the cache may be cold when the screen opens, and a
/// role changed under the open form reaches it the same way: one lost
/// swaps the form for a note. A later read never replaces what was typed:
/// the form and its bloc keep the household they opened with.
///
/// Decoupled from DI like the other household screens: the caller resolves
/// the [HouseholdRepository] and the per-server [HouseholdRemoteDataSource],
/// and leaves the screen in [onSaved].
///
/// The form holds its bloc, not a `BlocProvider`, so a save the user walks
/// away from still ends (#464). Left while one is under way, by the back
/// button or by a note taking the form's place, the bloc is kept until the
/// save settles. Then a SnackBar over whatever page is showing says it was
/// saved, or, since the form's banner went with it, that the household's
/// changes weren't, and the bloc closes, through `closeWhenSettled`. One that
/// settles while the route is still on its way out is said the same way. A
/// save that changed nothing says nothing. That late outcome never calls
/// [onSaved]: the user has already gone somewhere. No outcome is said once
/// [session] has ended, whether the form is gone or still leaving: it is no
/// news to whoever signs in next (#694). The bloc closes either way.
class EditHouseholdScreen extends StatelessWidget {
  const EditHouseholdScreen({
    required this.householdId,
    required this.repository,
    required this.remote,
    required this.session,
    required this.onSaved,
    this.onRefresh,
    super.key,
  });

  /// Key on the save-failure banner, for tests.
  static const Key errorKey = Key('edit_household.error');

  final String householdId;
  final HouseholdRepository repository;
  final HouseholdRemoteDataSource remote;

  /// The user session this screen was opened in, from the same container as
  /// [repository] and [remote]. A save that settles after the form is gone
  /// is said only while it is live (#694).
  final SessionLease session;

  /// Called once the edit is saved, with this screen's context. A
  /// confirmation SnackBar is already showing, above the route, unless the
  /// save changed nothing and so sent nothing. Not called for a save that
  /// lands once the user has left the form (#464).
  final void Function(BuildContext context) onSaved;

  /// Reads the user's households again, after an answer that says the
  /// cached one is out of date: it is gone, or this user may no longer
  /// edit it.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) => _EditHouseholdReads(
    // A new household is a new read, and a new form.
    key: ValueKey<String>(householdId),
    screen: this,
  );
}

/// One read of the cache: the household, or null when the cache does not
/// hold it for this user, and the viewer's role in it.
typedef _Read = ({Household? household, HouseholdRole? role});

class _EditHouseholdReads extends StatefulWidget {
  const _EditHouseholdReads({required this.screen, super.key});

  final EditHouseholdScreen screen;

  @override
  State<_EditHouseholdReads> createState() => _EditHouseholdReadsState();
}

class _EditHouseholdReadsState extends State<_EditHouseholdReads> {
  late final Stream<_Read> _reads = _watch();

  Stream<_Read> _watch() async* {
    yield await _read() ?? (household: null, role: null);
    try {
      await for (final _ in widget.screen.repository.watchMembers(
        widget.screen.householdId,
      )) {
        // A failed read again: the last answer stands, and so does the form.
        if (await _read() case final read?) yield read;
      }
    } on Object {
      // The last answer stands.
    }
  }

  Future<_Read?> _read() async {
    final repository = widget.screen.repository;
    final id = widget.screen.householdId;
    try {
      final (household, member) = await (
        repository.getHousehold(id),
        repository.getCurrentUserMember(id),
      ).wait;
      return (household: household, role: member?.role);
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    return StreamBuilder<_Read>(
      stream: _reads,
      builder: (context, snapshot) {
        final read = snapshot.data;
        if (read == null) {
          return BgePage(
            title: Text(l10n.editHouseholdTitle),
            centerVertically: true,
            child: BgeLoadingState(label: l10n.householdDetailLoading),
          );
        }
        final household = read.household;
        if (household == null) return _Note(l10n.editHouseholdNotFound);
        if (household.isLocalOnly) {
          return _Note(l10n.editHouseholdNotYetSynced);
        }
        if (!householdActionsFor(
          household,
          read.role,
        ).contains(HouseholdAction.edit)) {
          return _Note(l10n.editHouseholdNotAllowed);
        }
        return _EditHouseholdView(household: household, screen: widget.screen);
      },
    );
  }
}

/// Why there is no form, under the screen's title.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => BgePage(
    title: Text(HouseholdLocalizations.of(context).editHouseholdTitle),
    centerVertically: true,
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodyLarge,
      textAlign: TextAlign.center,
    ),
  );
}

class _EditHouseholdView extends StatefulWidget {
  const _EditHouseholdView({required this.household, required this.screen});

  /// The latest read. Only the first reaches the bloc and the form, which
  /// are created once.
  final Household household;
  final EditHouseholdScreen screen;

  @override
  State<_EditHouseholdView> createState() => _EditHouseholdViewState();
}

class _EditHouseholdViewState extends State<_EditHouseholdView> {
  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the form: a save still under way then would never say how it ended.
  /// See [dispose].
  late final EditHouseholdBloc _bloc;

  /// The lease the screen had when the bloc was made, beside the repository
  /// and remote it came from: [dispose] can't trust a later build's.
  late final SessionLease _session;

  /// The household's name as the form opened with it, and as a failed save
  /// leaves it: what a failure that lands after the form has gone names.
  late final String _name;

  /// The messenger above the route, which says a bar only while [_session] is
  /// live, and this screen's strings, captured while the form is mounted: a
  /// save that settles after it is gone is said with them, and [dispose] can't
  /// look them up.
  late final SessionMessenger _messenger = SessionMessenger(
    sessionIsLive: () => _session.isLive,
  );
  late HouseholdLocalizations _l10n;

  @override
  void initState() {
    super.initState();
    final screen = widget.screen;
    _session = screen.session;
    _name = widget.household.name;
    _bloc = EditHouseholdBloc(
      original: widget.household,
      remote: screen.remote,
      repository: screen.repository,
      onRefresh: screen.onRefresh,
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
    // Left with a save under way: it settles, is said while the session
    // lives, and the bloc closes then. Otherwise the form has already shown
    // whatever there was, and the bloc closes now.
    unawaited(
      closeWhenSettled<EditHouseholdState>(
        current: _bloc.state,
        states: _bloc.stream,
        underWay: (state) => state is EditHouseholdSaving,
        outcomeOf: _lateOutcome,
        say: _messenger.say,
        close: _bloc.close,
      ),
    );
    super.dispose();
  }

  /// What is said of a save that settled after the form went, or while it
  /// was going (#464): a save as the listener says it, and a failure, whose
  /// banner went with the form, by the household it was for. The banner's
  /// reason is left out: away from the form, there is nothing there to fix.
  /// A failure the server may have saved first, as the bloc counts it, is
  /// left open rather than said to be lost.
  String? _lateOutcome(EditHouseholdState state) => switch (state) {
    EditHouseholdSaved() => _savedMessage(_l10n, state),
    EditHouseholdFailed(
      reason: EditHouseholdFailure.offline || EditHouseholdFailure.unexpected,
    ) =>
      _l10n.editHouseholdUnconfirmedLate(_name),
    EditHouseholdFailed() => _l10n.editHouseholdNotSavedLate(_name),
    EditHouseholdEditing() || EditHouseholdSaving() => null,
  };

  /// Answers a save that has just ended.
  void _onEnded(BuildContext context, EditHouseholdState state) {
    // Popped or removed, and mounted only for its exit: the user has left,
    // so the outcome is said as it would be once the form had gone, a
    // failure too, and [EditHouseholdScreen.onSaved] is not called (#464).
    // By [dispose] it has settled, so `closeWhenSettled` says nothing more.
    if (ModalRoute.isActiveOf(context) == false) {
      _messenger.say(_lateOutcome(state));
      return;
    }
    // A failure stays: the form draws it as a banner.
    if (state case final EditHouseholdSaved saved) {
      // A SnackBar, since the next line takes this screen away; the
      // messenger outlives the route.
      _messenger.say(_savedMessage(_l10n, saved));
      widget.screen.onSaved(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    return BlocProvider<EditHouseholdBloc>.value(
      value: _bloc,
      child: BlocConsumer<EditHouseholdBloc, EditHouseholdState>(
        listenWhen: (_, state) =>
            state is EditHouseholdSaved || state is EditHouseholdFailed,
        listener: _onEnded,
        builder: (context, state) => BgePage(
          title: Text(l10n.editHouseholdTitle),
          child: EditHouseholdForm(
            initial: widget.household,
            // Saved counts too: the form is about to close.
            submitting:
                state is EditHouseholdSaving || state is EditHouseholdSaved,
            failure: switch (state) {
              EditHouseholdFailed(:final reason) => BgeFormFailure(
                key: EditHouseholdScreen.errorKey,
                title: l10n.editHouseholdErrorTitle,
                message: _failureMessage(l10n, reason),
              ),
              _ => null,
            },
            onEdited: () => context.read<EditHouseholdBloc>().add(
              const EditHouseholdEdited(),
            ),
            onSubmit: ({required name, description, memberInvitePolicy}) =>
                context.read<EditHouseholdBloc>().add(
                  EditHouseholdSubmitted(
                    name: name,
                    description: description,
                    memberInvitePolicy: memberInvitePolicy,
                  ),
                ),
          ),
        ),
      ),
    );
  }

  static String _failureMessage(
    HouseholdLocalizations l10n,
    EditHouseholdFailure reason,
  ) => switch (reason) {
    EditHouseholdFailure.offline => l10n.editHouseholdErrorOffline,
    EditHouseholdFailure.gone => l10n.editHouseholdErrorGone,
    EditHouseholdFailure.refused => l10n.editHouseholdErrorRefused,
    EditHouseholdFailure.invalid => l10n.editHouseholdErrorInvalid,
    EditHouseholdFailure.unexpected => l10n.editHouseholdErrorUnexpected,
  };
}

/// What the SnackBar says once an edit is saved, or null for a save that
/// changed nothing: it sent nothing, so nothing was updated. Said by the
/// listener as the form goes, or as a late outcome for a save that lands
/// once the user has left (#464).
String? _savedMessage(HouseholdLocalizations l10n, EditHouseholdSaved state) =>
    state.changed ? l10n.editHouseholdSaved : null;
