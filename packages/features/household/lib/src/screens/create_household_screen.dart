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
/// vs. still-queued) and reports the new household to [onCreated]; on an
/// unexpected local failure it shows an error and stays put.
///
/// The two outcomes use different surfaces on purpose (#191). Success takes
/// the user off this screen, so its confirmation has to outlive the route —
/// that is a SnackBar, owned by the ScaffoldMessenger above it. Failure stays
/// put, so it belongs on the screen as a [BgeInlineBanner].
class CreateHouseholdScreen extends StatelessWidget {
  const CreateHouseholdScreen({
    required this.repository,
    required this.remote,
    required this.onCreated,
    super.key,
  });

  /// Key on the create-failure banner, for tests.
  static const Key errorBannerKey = Key('create_household.error_banner');

  final HouseholdRepository repository;
  final HouseholdRemoteDataSource remote;

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
  Widget build(BuildContext context) {
    return BlocProvider<CreateHouseholdBloc>(
      create: (_) =>
          CreateHouseholdBloc(repository: repository, remote: remote),
      child: _CreateHouseholdView(onCreated: onCreated),
    );
  }
}

class _CreateHouseholdView extends StatelessWidget {
  const _CreateHouseholdView({required this.onCreated});

  final void Function(BuildContext context, String householdId) onCreated;

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
            // Deliberately a SnackBar: the next line takes this screen off
            // the stack, so an inline banner would be destroyed before it
            // could be read. The ScaffoldMessenger outlives the route. No
            // `Semantics(liveRegion:)` wrapper — SnackBar already is one
            // (`snack_bar.dart`), and nesting them makes screen readers
            // stutter (#191).
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  pendingSync
                      ? l10n.createHouseholdQueued
                      : l10n.createHouseholdSynced,
                ),
              ),
            );
            // Shown first, navigated second, and in that order: the
            // messenger has to receive the SnackBar while this route's
            // context is still current.
            //
            // No `maybePop` (#271 D2). The old pop-with-id is what #162 was:
            // on a root route it no-opped and left the user on the spent
            // form. Handing the id upward instead means the caller decides
            // where to go, and can do it with a replace that has no such
            // failure mode.
            onCreated(context, householdId);
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
