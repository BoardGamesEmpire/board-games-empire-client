import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/edit_household_bloc.dart';
import '../bloc/edit_household_event.dart';
import '../bloc/edit_household_state.dart';
import '../permissions/household_actions.dart';
import '../widgets/edit_household_form.dart';

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
class EditHouseholdScreen extends StatelessWidget {
  const EditHouseholdScreen({
    required this.householdId,
    required this.repository,
    required this.remote,
    required this.onSaved,
    this.onRefresh,
    super.key,
  });

  /// Key on the save-failure banner, for tests.
  static const Key errorKey = Key('edit_household.error');

  final String householdId;
  final HouseholdRepository repository;
  final HouseholdRemoteDataSource remote;

  /// Called once the edit is saved, with this screen's context. A
  /// confirmation SnackBar is already showing, above the route, unless the
  /// save changed nothing and so sent nothing.
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
            child: const Center(child: CircularProgressIndicator()),
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

class _EditHouseholdView extends StatelessWidget {
  const _EditHouseholdView({required this.household, required this.screen});

  /// The latest read. Only the first reaches the bloc and the form, which
  /// are created once.
  final Household household;
  final EditHouseholdScreen screen;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    return BlocProvider(
      create: (_) => EditHouseholdBloc(
        original: household,
        remote: screen.remote,
        repository: screen.repository,
        onRefresh: screen.onRefresh,
      ),
      child: BlocConsumer<EditHouseholdBloc, EditHouseholdState>(
        listenWhen: (_, state) => state is EditHouseholdSaved,
        listener: (context, state) {
          // A SnackBar, since the next line takes this screen away; the
          // messenger outlives the route. Not for a save that sent nothing:
          // nothing was updated.
          if (state case EditHouseholdSaved(changed: true)) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(l10n.editHouseholdSaved)));
          }
          screen.onSaved(context);
        },
        builder: (context, state) => BgePage(
          title: Text(l10n.editHouseholdTitle),
          child: EditHouseholdForm(
            initial: household,
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
