import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/create_household_bloc.dart';
import '../bloc/create_household_event.dart';
import '../bloc/create_household_state.dart';
import '../widgets/create_household_form.dart';

/// Screen for creating a household (#40).
///
/// Decoupled from DI: the caller (router / app shell) resolves the
/// per-server [HouseholdRepository] and [HouseholdRemoteDataSource] from the
/// active server scope and passes them in; the screen provides the
/// [CreateHouseholdBloc] itself. On success it shows a confirmation (synced
/// vs. still-queued) and pops with the household id; on an unexpected local
/// failure it shows an error and stays put.
///
/// The two outcomes use different surfaces on purpose (#191). Success pops
/// the screen, so its confirmation has to outlive the route — that is a
/// SnackBar, owned by the ScaffoldMessenger above it. Failure stays put, so
/// it belongs on the screen as a [BgeInlineBanner].
class CreateHouseholdScreen extends StatelessWidget {
  const CreateHouseholdScreen({
    required this.repository,
    required this.remote,
    super.key,
  });

  /// Key on the create-failure banner, for tests.
  static const Key errorBannerKey = Key('create_household.error_banner');

  final HouseholdRepository repository;
  final HouseholdRemoteDataSource remote;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<CreateHouseholdBloc>(
      create: (_) =>
          CreateHouseholdBloc(repository: repository, remote: remote),
      child: const _CreateHouseholdView(),
    );
  }
}

class _CreateHouseholdView extends StatelessWidget {
  const _CreateHouseholdView();

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    return BlocConsumer<CreateHouseholdBloc, CreateHouseholdState>(
      // Success only: failure renders as a banner from the builder, so
      // waking the listener for it would buy an empty switch arm.
      listenWhen: (_, state) => state is CreateHouseholdSuccess,
      listener: (context, state) {
        switch (state) {
          case CreateHouseholdSuccess(:final householdId, :final pendingSync):
            // Deliberately a SnackBar: the next line pops this screen, so an
            // inline banner would be destroyed before it could be read. The
            // ScaffoldMessenger outlives the route. No `Semantics(liveRegion:)`
            // wrapper — SnackBar already is one (`snack_bar.dart`), and
            // nesting them makes screen readers stutter (#191).
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  pendingSync
                      ? l10n.createHouseholdQueued
                      : l10n.createHouseholdSynced,
                ),
              ),
            );
            Navigator.of(context).maybePop(householdId);
          case CreateHouseholdFailure():
          case CreateHouseholdInitial():
          case CreateHouseholdSubmitting():
            break;
        }
      },
      builder: (context, state) {
        final submitting = state is CreateHouseholdSubmitting;
        return BgePage(
          title: Text(l10n.createHouseholdTitle),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state is CreateHouseholdFailure) ...[
                BgeInlineBanner(
                  key: CreateHouseholdScreen.errorBannerKey,
                  tone: BgeBannerTone.error,
                  message: l10n.createHouseholdError,
                ),
                const BgeGap.md(),
              ],
              CreateHouseholdForm(
                submitting: submitting,
                // Retire the banner as soon as the user edits: it describes
                // the value they are replacing, and being bound to bloc
                // state it does not fade the way a SnackBar would (#191).
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
            ],
          ),
        );
      },
    );
  }
}
