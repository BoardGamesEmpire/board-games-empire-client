import 'package:flutter/material.dart';
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
class CreateHouseholdScreen extends StatelessWidget {
  const CreateHouseholdScreen({
    required this.repository,
    required this.remote,
    super.key,
  });

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
      listenWhen: (_, state) =>
          state is CreateHouseholdSuccess || state is CreateHouseholdFailure,
      listener: (context, state) {
        final messenger = ScaffoldMessenger.of(context);
        switch (state) {
          case CreateHouseholdSuccess(:final householdId, :final pendingSync):
            messenger.showSnackBar(
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
            messenger.showSnackBar(
              SnackBar(content: Text(l10n.createHouseholdError)),
            );
          case CreateHouseholdInitial():
          case CreateHouseholdSubmitting():
            break;
        }
      },
      builder: (context, state) {
        final submitting = state is CreateHouseholdSubmitting;
        return Scaffold(
          appBar: AppBar(title: Text(l10n.createHouseholdTitle)),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: CreateHouseholdForm(
                submitting: submitting,
                onSubmit: ({required name, description}) =>
                    context.read<CreateHouseholdBloc>().add(
                      CreateHouseholdSubmitted(
                        name: name,
                        description: description,
                      ),
                    ),
              ),
            ),
          ),
        );
      },
    );
  }
}
