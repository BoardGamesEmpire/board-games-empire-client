import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';

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
///
/// ## Access
///
/// The save is offered while the caller's access allows it: create for an
/// add, update for an edit (#456). Without it the fields are read-only, and
/// once access has answered the form says why in its place. While it has
/// not, the form says nothing about the role. An add the caller may not make
/// shows access-denied instead, and opens if that changes.
///
/// A save that access takes away with keyboard focus on it hands focus to the
/// last field ([DataGatewayForm]). An open add that access closes with focus
/// inside it hands focus to the page's heading, which is no Tab stop but is
/// always there.
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

  /// The session's access, or null for a composition without one, which
  /// opens the form read-only.
  final CallerAccessRepository? access;

  /// The DataGateway to edit, or null to add one.
  final String? editingId;

  /// Leaves the form after a save. Required: a save with nowhere to go
  /// strands the user on a spent form (#162, #271).
  ///
  /// Called once the form's route is current: after the page covering the
  /// form leaves, for a save that lands under it. Not called for a save that
  /// lands once the user has gone back.
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

class _DataGatewayFormView extends StatefulWidget {
  const _DataGatewayFormView({required this.editing, required this.onDone});

  final bool editing;
  final void Function(BuildContext context) onDone;

  @override
  State<_DataGatewayFormView> createState() => _DataGatewayFormViewState();
}

class _DataGatewayFormViewState extends State<_DataGatewayFormView> {
  /// On the page's heading, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'data gateway form heading',
    skipTraversal: true,
  );

  /// The node of the [Focus] around the form. It can't take focus itself:
  /// focus goes to the fields and the submit inside.
  final FocusNode _form = FocusNode(
    debugLabel: 'data gateway form',
    canRequestFocus: false,
  );

  @override
  void dispose() {
    _heading.dispose();
    _form.dispose();
    super.dispose();
  }

  /// Whether [current] takes the open form away because the caller's access
  /// no longer allows an add (#456).
  static bool _closesForm(
    DataGatewayFormState previous,
    DataGatewayFormState current,
  ) => previous is DataGatewayFormEditing && current is DataGatewayFormDenied;

  /// When the form goes with keyboard focus inside it, hands focus to the
  /// page's heading (#456).
  ///
  /// Access can fall at any time, whenever the session asks again. Left to go
  /// with the form, focus would fall on the page with nothing to show for it.
  /// The access-denied message that replaces the form has no control, and
  /// the heading is always there. The next Tab goes on from the top of the
  /// page.
  ///
  /// Runs before the frame that takes the form away, while it still has
  /// focus.
  void _onFormClosed(BuildContext context, DataGatewayFormState state) {
    if (!_form.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _heading.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

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
    DataGatewayFormFailure.refused => l10n.dataGatewayChangeRefused,
    DataGatewayFormFailure.failed => l10n.dataGatewayFormFailed,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = DataGatewayLocalizations.of(context);
    final editing = widget.editing;
    final title = Focus(
      focusNode: _heading,
      child: Text(
        editing ? l10n.dataGatewayFormEditTitle : l10n.dataGatewayAdd,
      ),
    );

    return BlocListener<DataGatewayFormBloc, DataGatewayFormState>(
      listenWhen: _closesForm,
      listener: _onFormClosed,
      child: BlocConsumer<DataGatewayFormBloc, DataGatewayFormState>(
        listenWhen: (_, state) => state is DataGatewayFormSaved,
        listener: (context, state) {
          if (state is! DataGatewayFormSaved) return;
          // Shown before leaving, while this route's context is still mounted;
          // the messenger outlives the route. Shown however the save finds the
          // form, because the save happened either way.
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(_savedMessage(l10n, state))));
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
                child: const ExcludeSemantics(
                  child: CircularProgressIndicator(),
                ),
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
            :final maySave,
            :final accessKnown,
            :final failure,
          ) =>
            BgePage(
              title: title,
              child: Focus(
                focusNode: _form,
                child: DataGatewayForm(
                  initial: original,
                  submitLabel: editing
                      ? l10n.dataGatewayFormSubmitEdit
                      : l10n.dataGatewayFormSubmitAdd,
                  submitting: submitting,
                  maySave: maySave,
                  accessKnown: accessKnown,
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
            ),
          // Until the route is gone, keep the form's shape rather than flashing
          // an empty page.
          DataGatewayFormSaved() => BgePage(
            title: title,
            child: _LeaveWhenCurrent(onDone: widget.onDone),
          ),
        },
      ),
    );
  }
}

/// Calls [onDone] once the form's route is the current one.
///
/// That is at once for a save that lands in view. A save can also land while
/// a page covers the form, and then the form leaves when the user comes back
/// to it; leaving at once would close the page on top. And a save can land
/// after the user went back, while the form is still on its way out. Its
/// route is never current again, so it never leaves: the user already has,
/// and leaving again would close the screen beneath.
class _LeaveWhenCurrent extends StatefulWidget {
  const _LeaveWhenCurrent({required this.onDone});

  final void Function(BuildContext context) onDone;

  @override
  State<_LeaveWhenCurrent> createState() => _LeaveWhenCurrentState();
}

class _LeaveWhenCurrentState extends State<_LeaveWhenCurrent> {
  bool _left = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depends on whether the route is current, so this runs again when it
    // becomes so.
    if (_left || !(ModalRoute.isCurrentOf(context) ?? true)) return;
    _left = true;
    // Leaving is a navigation, which may not start while widgets build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDone(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
