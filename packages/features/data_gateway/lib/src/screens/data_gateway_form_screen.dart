import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

import '../access/data_gateway_access.dart';
import '../bloc/data_gateway_form_bloc.dart';
import '../bloc/data_gateway_form_event.dart';
import '../bloc/data_gateway_form_state.dart';
import '../widgets/data_gateway_form.dart';
import '../widgets/data_gateway_message.dart';

/// The add form, or the edit form when [editingId] is set (#41).
///
/// Decoupled from DI like the list screen. A save confirms itself in a
/// SnackBar and then calls [onDone], because the confirmation has to outlive
/// the route the way the household create flow's does (#191). Every failure
/// stays on the form, above the submit it answers.
class DataGatewayFormScreen extends StatelessWidget {
  const DataGatewayFormScreen({
    required this.remote,
    required this.onDone,
    this.access,
    this.editingId,
    super.key,
  });

  static const Key loadingKey = Key('data_gateway_form.loading');
  static const Key errorBannerKey = Key('data_gateway_form.error_banner');

  final DataGatewayRemoteDataSource remote;
  final DataGatewayAccess? access;

  /// The DataGateway to edit, or null to add one.
  final String? editingId;

  /// Leaves the form after a save. Required: a save with nowhere to go
  /// strands the user on a spent form (#162, #271).
  ///
  /// Not called for a save that lands once the user has gone back.
  final void Function(BuildContext context) onDone;

  @override
  Widget build(BuildContext context) => BlocProvider<DataGatewayFormBloc>(
    // Keyed on the row: go_router keys a page by its path pattern, so going
    // from one edit location straight to another rebuilds this screen in
    // place. A new id has to start a new bloc and new fields, or the form
    // would show and save the first row under the second's URL.
    key: ValueKey<String?>(editingId),
    create: (_) => DataGatewayFormBloc(
      remote: remote,
      access: access,
      editingId: editingId,
    )..add(const DataGatewayFormStarted()),
    child: _DataGatewayFormView(editing: editingId != null, onDone: onDone),
  );
}

class _DataGatewayFormView extends StatelessWidget {
  const _DataGatewayFormView({required this.editing, required this.onDone});

  final bool editing;
  final void Function(BuildContext context) onDone;

  static String _savedMessage(
    DataGatewayLocalizations l10n,
    DataGatewayFormSaved saved,
  ) {
    final name = saved.result.dataGateway.name;
    if (!saved.created) return l10n.dataGatewaySaved(name);
    return switch (saved.result.connectionAttempt?.succeeded) {
      true => l10n.dataGatewayAddedConnected(name),
      false => l10n.dataGatewayAddedNotConnected(name),
      null => l10n.dataGatewayAdded(name),
    };
  }

  static String _failureMessage(
    DataGatewayLocalizations l10n,
    DataGatewayFormFailure failure,
  ) => switch (failure) {
    DataGatewayFormFailure.nothingChanged => l10n.dataGatewayFormNothingChanged,
    DataGatewayFormFailure.nameInUse => l10n.dataGatewayFormNameInUse,
    DataGatewayFormFailure.gone => l10n.dataGatewayFormGone,
    DataGatewayFormFailure.failed => l10n.dataGatewayFormFailed,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final title = Text(
      editing ? l10n.dataGatewayFormEditTitle : l10n.dataGatewayAdd,
    );

    return BlocConsumer<DataGatewayFormBloc, DataGatewayFormState>(
      listenWhen: (_, state) => state is DataGatewayFormSaved,
      listener: (context, state) {
        if (state is! DataGatewayFormSaved) return;
        // Shown before leaving, while this route's context is still mounted;
        // the messenger outlives the route.
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_savedMessage(l10n, state))));
        // A save can land after the user went back, while this route is still
        // on its way out. The save still happened, so it is still confirmed,
        // but the user has already left: leaving again would close the
        // screen beneath.
        if (ModalRoute.of(context)?.isCurrent ?? true) onDone(context);
      },
      builder: (context, state) => switch (state) {
        DataGatewayFormLoading() => BgePage(
          title: title,
          centerVertically: true,
          child: Center(
            key: DataGatewayFormScreen.loadingKey,
            child: Semantics(
              liveRegion: true,
              label: l10n.dataGatewayFormLoading,
              child: const ExcludeSemantics(child: CircularProgressIndicator()),
            ),
          ),
        ),
        DataGatewayFormDenied() => BgePage(
          title: title,
          centerVertically: true,
          child: DataGatewayMessage(
            icon: Icons.lock_outline,
            title: l10n.dataGatewayDeniedTitle,
            body: l10n.dataGatewayDeniedBody,
          ),
        ),
        DataGatewayFormMissing() => BgePage(
          title: title,
          centerVertically: true,
          child: DataGatewayMessage(
            icon: Icons.search_off_outlined,
            title: l10n.dataGatewayFormMissingTitle,
            body: l10n.dataGatewayFormMissingBody,
          ),
        ),
        DataGatewayFormLoadFailed() => BgePage(
          title: title,
          centerVertically: true,
          child: BgeErrorState(
            icon: Icons.cloud_off_outlined,
            title: l10n.dataGatewayFormLoadFailedTitle,
            body: l10n.dataGatewayListErrorBody,
            retryLabel: l10n.dataGatewayRetry,
            onRetry: () => context.read<DataGatewayFormBloc>().add(
              const DataGatewayFormStarted(),
            ),
          ),
        ),
        DataGatewayFormEditing(
          :final original,
          :final submitting,
          :final mayChange,
          :final failure,
        ) =>
          BgePage(
            title: title,
            child: DataGatewayForm(
              initial: original,
              submitLabel: editing
                  ? l10n.dataGatewayFormSubmitEdit
                  : l10n.dataGatewayFormSubmitAdd,
              submitting: submitting,
              mayChange: mayChange,
              failure: failure == null
                  ? null
                  : BgeFormFailure(
                      key: DataGatewayFormScreen.errorBannerKey,
                      // Each message names what happened on its own.
                      title: null,
                      message: _failureMessage(l10n, failure),
                    ),
              onEdited: () => context.read<DataGatewayFormBloc>().add(
                const DataGatewayFormFailureCleared(),
              ),
              onSubmit: (input) => context.read<DataGatewayFormBloc>().add(
                DataGatewayFormSubmitted(input),
              ),
            ),
          ),
        // The listener above leaves the route. Until it is gone, keep the
        // form's shape rather than flashing an empty page.
        DataGatewayFormSaved() => BgePage(
          title: title,
          child: const SizedBox.shrink(),
        ),
      },
    );
  }
}
