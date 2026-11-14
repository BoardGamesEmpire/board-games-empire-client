import 'dart:async';

import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:data_gateway/src/bloc/data_gateway_form_bloc.dart';
import 'package:data_gateway/src/bloc/data_gateway_form_event.dart';
import 'package:data_gateway/src/bloc/data_gateway_form_state.dart';
import 'package:data_gateway/src/widgets/data_gateway_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

/// The add form, or the edit form when [editingId] is set (#41).
///
/// Decoupled from DI like the list screen. A save confirms itself in a
/// SnackBar and then calls [onDone], because the confirmation has to outlive
/// the route the way the household create flow's does (#191). Every failure
/// stays on the form, above the submit it answers.
///
/// ## A save that outlives the form
///
/// The form holds its bloc, not a `BlocProvider`, so a save the user walks
/// away from still ends (#464). Left while one is under way, by the back
/// button or by a `go` to another row, the bloc is kept until the save
/// settles. Then a SnackBar over whatever page is showing says it was saved,
/// or, since the form's banner went with it, that it failed, and the bloc
/// closes, through `closeWhenSettled`. One that settles while the route is
/// still on its way out is said the same way. That late outcome never calls
/// [onDone]: the user has already gone somewhere. No outcome is said once
/// [session] has ended, whether the form is gone or still leaving: it is no
/// news to whoever signs in next (#694). The bloc closes either way.
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
    required this.session,
    required this.onDone,
    this.access,
    this.editingId,
    super.key,
  });

  static const Key loadingKey = Key('data_gateway_form.loading');
  static const Key errorBannerKey = Key('data_gateway_form.error_banner');

  final DataGatewayRemoteDataSource remote;

  /// The user session this screen was opened in, from the same container as
  /// [remote] and [access]. A save that settles after the form is gone is
  /// said only while it is live (#694).
  final SessionLease session;

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
  Widget build(BuildContext context) => _DataGatewayFormOwner(
    // Keyed on the row: go_router keys a page by its path pattern, so going
    // from one edit location straight to another rebuilds this screen in
    // place. A new id has to start a new bloc and new fields, or the form
    // would show and save the first row under the second's URL. The old
    // bloc is not lost with it: its owner closes it once its save settles.
    key: ValueKey<String?>(editingId),
    screen: this,
  );
}

/// Owns the form's bloc, so it can outlive the form's route while a save is
/// under way (#464). Held here rather than by a `BlocProvider`, which would
/// close it with the form: a save still under way then would never say how
/// it ended. See `dispose`.
class _DataGatewayFormOwner extends StatefulWidget {
  const _DataGatewayFormOwner({required this.screen, super.key});

  final DataGatewayFormScreen screen;

  @override
  State<_DataGatewayFormOwner> createState() => _DataGatewayFormOwnerState();
}

class _DataGatewayFormOwnerState extends State<_DataGatewayFormOwner> {
  late final DataGatewayFormBloc _bloc;

  /// The lease the screen had when the bloc was made, beside the remote and
  /// access it came from: [dispose] can't trust a later build's.
  late final SessionLease _session;

  /// The messenger above the route, which says a bar only while [_session] is
  /// live, and this screen's strings, captured while the form is mounted: a
  /// save that settles after it is gone is said with them, and [dispose] can't
  /// look them up.
  late final SessionMessenger _messenger = SessionMessenger(
    sessionIsLive: () => _session.isLive,
  );
  late DataGatewayLocalizations _l10n;

  @override
  void initState() {
    super.initState();
    final screen = widget.screen;
    _session = screen.session;
    _bloc = DataGatewayFormBloc(
      remote: screen.remote,
      access: screen.access,
      editingId: screen.editingId,
    )..add(const DataGatewayFormStarted());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger.attach(context);
    _l10n = DataGatewayLocalizations.of(context);
  }

  @override
  void dispose() {
    // Left with a save under way: it settles, is said while the session
    // lives, and the bloc closes then. Otherwise the form has already shown
    // whatever there was, and the bloc closes now.
    unawaited(
      closeWhenSettled<DataGatewayFormState>(
        current: _bloc.state,
        states: _bloc.stream,
        underWay: _underWay,
        outcomeOf: (state) => _outcomeOf(_l10n, state),
        say: _messenger.say,
        close: _bloc.close,
      ),
    );
    super.dispose();
  }

  static bool _underWay(DataGatewayFormState state) =>
      state is DataGatewayFormEditing && state.submitting;

  /// Answers a save that has just settled. Leaving after it is
  /// [_LeaveWhenCurrent]'s, which leaves only a route that is current.
  void _onSettled(BuildContext context, DataGatewayFormState state) {
    // Popped or removed, and mounted only for its exit: the user has left,
    // so the outcome is said as it would be once the form had gone, a
    // failure too (#464). By [dispose] it has settled, so `closeWhenSettled`
    // says nothing more.
    if (ModalRoute.isActiveOf(context) == false) {
      _messenger.say(_outcomeOf(_l10n, state));
      return;
    }
    // A failure stays: the form draws it as a banner.
    if (state case final DataGatewayFormSaved saved) {
      // Shown before leaving, while this route's context is still mounted;
      // the messenger outlives the route. Shown whether the save finds the
      // form in view or covered, because the save happened either way.
      _messenger.say(_savedMessage(_l10n, saved));
    }
  }

  @override
  Widget build(BuildContext context) => BlocProvider<DataGatewayFormBloc>.value(
    value: _bloc,
    child: BlocListener<DataGatewayFormBloc, DataGatewayFormState>(
      listenWhen: (previous, current) =>
          _underWay(previous) && !_underWay(current),
      listener: _onSettled,
      child: _DataGatewayFormView(
        editing: widget.screen.editingId != null,
        onDone: widget.screen.onDone,
      ),
    ),
  );
}

/// What is said of a save that settled once the user had left the form,
/// after it went or while it was going (#464), or null for a state that is
/// no outcome: a save as the listener says it, and a failure, whose banner
/// went with the form, as a bar that names what wasn't saved and asks
/// nothing of a form that is gone.
///
/// A refusal for the user's role is said as the role's refusal, as on the
/// form. An add that fails once access no longer allows it settles as
/// [DataGatewayFormDenied], not as a failure: the form would have shown
/// access-denied in its place. Said late, it is that refusal too, since
/// trying again would fail the same way.
String? _outcomeOf(DataGatewayLocalizations l10n, DataGatewayFormState state) =>
    switch (state) {
      DataGatewayFormSaved() => _savedMessage(l10n, state),
      DataGatewayFormEditing(failure: DataGatewayFormFailure.refused) ||
      DataGatewayFormDenied() => l10n.dataGatewayChangeRefused,
      DataGatewayFormEditing(failure: != null, :final original?) =>
        l10n.dataGatewaySaveFailedLate(original.name),
      DataGatewayFormEditing(failure: != null) => l10n.dataGatewayAddFailedLate,
      _ => null,
    };

String _savedMessage(
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
  /// focus, and hands it on after that frame. Not if the user has moved focus
  /// meanwhile, and not if access has opened the form again by then.
  void _onFormClosed(BuildContext context, DataGatewayFormState state) {
    if (!_form.hasFocus) return;
    final focused = FocusManager.instance.primaryFocus;
    final bloc = context.read<DataGatewayFormBloc>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          focusIsFree(this.context, untouched: focused) &&
          bloc.state is DataGatewayFormDenied) {
        _heading.requestFocus();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
      child: BlocBuilder<DataGatewayFormBloc, DataGatewayFormState>(
        builder: (context, state) => switch (state) {
          DataGatewayFormLoading() => BgePage(
            title: title,
            centerVertically: true,
            child: Center(
              child: BgeLoadingState(
                key: DataGatewayFormScreen.loadingKey,
                label: l10n.dataGatewayFormLoading,
              ),
            ),
          ),
          DataGatewayFormDenied() => BgePage(
            title: title,
            centerVertically: true,
            child: BgeEmptyState(
              icon: Icons.lock_outline,
              title: l10n.dataGatewayDeniedTitle,
              body: l10n.dataGatewayDeniedBody,
            ),
          ),
          DataGatewayFormMissing() => BgePage(
            title: title,
            centerVertically: true,
            child: BgeEmptyState(
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
