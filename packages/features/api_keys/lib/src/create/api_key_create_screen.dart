import 'dart:async';

import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:api_keys/src/create/api_key_create_bloc.dart';
import 'package:api_keys/src/create/api_key_create_event.dart';
import 'package:api_keys/src/create/api_key_create_leave_guard.dart';
import 'package:api_keys/src/create/api_key_create_state.dart';
import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:api_keys/src/form/api_key_name_control.dart';
import 'package:api_keys/src/widgets/api_key_submit_button.dart';
import 'package:api_keys/src/widgets/critical_confirm_dialog.dart';
import 'package:api_keys/src/widgets/expiry_control.dart';
import 'package:api_keys/src/widgets/scope_picker.dart';
import 'package:api_keys/src/widgets/secret_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Makes an API key (#1028), then shows its secret the one time the server
/// gives it.
///
/// ## The form
///
/// A name, the permissions the key is to hold ([ScopePicker], with
/// "Everything I can do"), how long it lasts ([ExpiryControl], 90 days to
/// start with) and Create. Online only: the permissions on offer are read
/// from the server when the page opens, and Create goes straight to it, so
/// offline Create is disabled and says why (#49). "Everything I can do"
/// turned off again gives back the picks made before it went on.
///
/// A key may be made with no permissions. The picker says it will work
/// nowhere, in a warning that is not read out until the user has changed
/// the picks: on a form nobody has touched it is how the form starts.
///
/// A press of Create the form refuses moves focus to the first field at
/// fault. While a create is on its way the fields are read-only, not
/// disabled, and Create stays enabled and ignores presses, so each keeps
/// its place in the focus order and Create keeps focus (STYLE_GUIDE §5,
/// and its "In-flight forms"). Create's name says it is creating, in a
/// live region while it is.
///
/// ## A Critical permission
///
/// A key that would hold a Critical permission is asked about first
/// ([showCriticalConfirm]), by name: one the user picked, or any the user may
/// give when "Everything I can do" is on, since that gives them all. Cancel
/// sends nothing. Only a yes sends `confirmCritical`.
///
/// The server can find a permission Critical that the form did not, when
/// the permissions changed after the form read them. It then refuses the
/// unconfirmed create, the bloc reads the permissions again, and the same
/// question comes up with what is Critical now. A yes sends the create once
/// more, confirmed. If the server refuses that one the same way, it is a
/// failure like any other, and nothing asks again.
///
/// ## Failures
///
/// A failed create shows in a banner on Create, titled, worded by
/// [apiKeyFailureMessage], until the user edits the form or presses Create
/// again. A refusal that names a permission is also said on that
/// permission's row. A stale sign-in is answered in words, with no action
/// (#1113).
///
/// ## The secret
///
/// Once the server makes the key, the page's body becomes a [SecretPanel]:
/// the same route, with the secret in the bloc's state and nowhere else. It
/// is in no route argument and nothing restores it, so a reload or a link
/// opens the form, never a panel with no secret to show. Nothing times it
/// out. Focus goes to the page's title as the form leaves, and the page
/// scrolls back to its top.
///
/// Done leaves. Back asks first, saying the key won't be shown again, with
/// Stay and Leave. While a create is on its way Back waits, since the
/// answer would be lost with the page.
///
/// There are two ways a route is taken away, and the page answers both
/// with the one question. While it is open, anything more that would take
/// the route waits on its answer, and opens no second one:
///
/// - **A pop**: the page's back arrow and System Back. The page refuses it
///   while the panel shows or a create is on its way, and a back swipe has
///   nothing to drag. System Back on the open question closes the
///   question, and the page stays.
/// - **The router taking the route without a pop**: the browser's Back and
///   Forward, which reach the router as a new location, and a move to
///   another location, as a pick in the navigation menu makes. A page can't
///   refuse that itself, so whatever holds its route asks [leaveGuard]
///   first, and keeps the route when the answer is no. Where the browser
///   owns Back a page shows no back arrow of its own, so this is the only
///   way Back is heard there.
///
/// Done and Leave are let through without another question, whichever way
/// the route then goes. So is everything once [sessionLease] has ended: a
/// session that is ending takes its pages with it, and asks nothing.
///
/// ## Another server
///
/// The page makes its own [ApiKeyCreateBloc], and a new [remote] makes a
/// new page, form and bloc, so one server's secret never shows under
/// another's.
class ApiKeyCreateScreen extends StatelessWidget {
  const ApiKeyCreateScreen({
    required this.remote,
    this.leaveGuard,
    this.sessionLease,
    super.key,
  });

  static const Key loadingKey = Key('api_key_create.loading');
  static const Key failedKey = Key('api_key_create.failed');
  static const Key retryKey = Key('api_key_create.retry');

  /// On the name's field.
  static const Key nameKey = Key('api_key_create.name');

  /// On Create's `FilledButton`.
  static const Key submitKey = Key('api_key_create.submit');

  /// The banner on Create when a create failed.
  static const Key errorKey = Key('api_key_create.error');

  /// Stay, in the question Back asks while the secret shows.
  static const Key leaveStayKey = Key('api_key_create.leave_stay');

  /// Leave, in the question Back asks while the secret shows.
  static const Key leaveConfirmKey = Key('api_key_create.leave_confirm');

  final ApiKeyRemoteDataSource remote;

  /// What the holder of this page's route asks before it takes the route
  /// away without a pop: see "The secret". Null where nothing takes a route
  /// that way.
  final ApiKeyCreateLeaveGuard? leaveGuard;

  /// The user session [remote] came from. Once it has ended the page lets
  /// its route go without a question. Null is a session that never ends.
  final SessionLease? sessionLease;

  @override
  Widget build(BuildContext context) => _ApiKeyCreate(
    // A new remote is another server: a new form and a new bloc, and never
    // the last one's secret.
    key: ObjectKey(remote),
    screen: this,
  );
}

/// A create as the page sent it, kept to send again once the server's
/// question is answered, and to tell that question from a failure.
typedef _Sent = ({
  String name,
  ScopeSelection selection,
  int days,
  bool confirmCritical,
});

/// [selection] without any pick whose permission [grantable] doesn't have:
/// its row is gone, so nothing shows it ticked, and it can't be given.
ScopeSelection _grantableOnly(
  ScopeSelection selection,
  List<GrantablePermission> grantable,
) => switch (selection) {
  EverythingScopes() => selection,
  PickedScopes(:final scopes) => PickedScopes([
    for (final scope in scopes)
      if (grantable.any((permission) => permission.slug == scope.slug)) scope,
  ]),
};

/// The page for one remote: its form, and its bloc, which holds the secret.
class _ApiKeyCreate extends StatefulWidget {
  const _ApiKeyCreate({required this.screen, super.key});

  final ApiKeyCreateScreen screen;

  @override
  State<_ApiKeyCreate> createState() => _ApiKeyCreateState();
}

class _ApiKeyCreateState extends State<_ApiKeyCreate> {
  static const _nameControl = 'name';
  static const _customDaysControl = 'customDays';

  /// Made once, with this State, and closed with it. Nothing that rebuilds
  /// the page makes another, so a resized window or a parent's rebuild keeps
  /// the secret it holds.
  late final ApiKeyCreateBloc _bloc = ApiKeyCreateBloc(widget.screen.remote)
    ..add(const ApiKeyCreateStarted());

  /// The lease of the session the bloc's remote came from, taken as the
  /// page is made, as a later build's may be another session's.
  late final SessionLease? _session = widget.screen.sessionLease;

  /// Takes this page off the guard it answers, once it is on one.
  void Function()? _detachGuard;

  late final FormGroup _form = FormGroup({
    _nameControl: apiKeyNameControl(),
    // The expiry's custom field: part of this form, so a bad number there
    // makes the form invalid and is what a refused Create focuses.
    _customDaysControl: expiryCustomDaysControl(),
  });
  StreamSubscription<Object?>? _edits;

  ScopeSelection _selection = const PickedScopes([]);

  /// The picks made before "Everything I can do" went on, which it gives
  /// back when it goes off.
  PickedScopes _beforeEverything = const PickedScopes([]);

  /// Whether the user has changed the picks, which makes the picker's
  /// nothing-picked warning news rather than how the form starts.
  bool _picksChanged = false;

  /// The days chosen. Null only while "Custom" holds no valid number, which
  /// makes the form invalid.
  int? _days = ApiKeyRemoteDataSource.defaultExpiryDays;

  /// The last create sent.
  _Sent? _sent;

  /// Whether the Critical question is open, so nothing opens a second.
  bool _asking = false;

  /// Back's question while it is open, so that a second way out arriving
  /// meanwhile waits on the same answer and asks nothing more.
  Future<bool>? _leaveQuestion;

  /// Whether Back's question has been asked. It says the key won't be shown
  /// again, so the panel's warning beneath it is not said again after.
  bool _leaveAsked = false;

  /// Whether the page is popping itself, by Done or by Leave after a pop
  /// it refused. The user has answered, so [_mayLeave] says yes to whatever
  /// carries that pop out.
  bool _leaving = false;

  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop. Where focus goes when the control that had it goes.
  final FocusNode _heading = FocusNode(
    debugLabel: 'Create API key heading',
    skipTraversal: true,
  );

  /// Create's focus node, owned by its [BgeInertButton] and taken from its
  /// builder, so a press can give Create focus before a question opens.
  FocusNode? _createFocus;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // A failure describes the values it was sent with, so an edit retires
    // it. The picks and the expiry's chips, which are no controls of the
    // form, do the same where they change.
    _edits = _form.valueChanges.listen((_) => _retireFailure());
    _detachGuard = widget.screen.leaveGuard?.attach(_mayLeave);
  }

  @override
  void dispose() {
    _detachGuard?.call();
    unawaited(_edits?.cancel());
    _form.dispose();
    _heading.dispose();
    _scroll.dispose();
    // The secret goes with it. A create still on its way ends unheard.
    unawaited(_bloc.close());
    super.dispose();
  }

  void _retireFailure() {
    if (!_bloc.isClosed) _bloc.add(const ApiKeyCreateFailureCleared());
  }

  void _retry() {
    // Try again goes as the read starts, and would take focus with it.
    _heading.requestFocus();
    _bloc.add(const ApiKeyCreateStarted());
  }

  void _onPicked(ScopeSelection selection) {
    final previous = _selection;
    // On, what was picked is kept for when it goes off.
    if (previous is PickedScopes && selection is EverythingScopes) {
      _beforeEverything = previous;
    }
    setState(() {
      _selection = switch ((previous, selection)) {
        // Off: the picks made before it went on, and any the picker kept.
        (EverythingScopes(), PickedScopes(:final scopes)) => PickedScopes([
          ..._beforeEverything.scopes,
          for (final scope in scopes)
            if (!_beforeEverything.scopes.contains(scope)) scope,
        ]),
        _ => selection,
      };
      _picksChanged = true;
    });
    _retireFailure();
  }

  void _onDays(int? days) {
    setState(() => _days = days);
    _retireFailure();
  }

  Future<void> _submit() async {
    final state = _bloc.state;
    // Creating is a direct write (#49). Returning before the validity check
    // keeps an offline press from marking the form touched.
    if (_asking ||
        state.submitting ||
        state.created != null ||
        BgeConnectivityScope.offlineOf(context)) {
      return;
    }
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final days = _days;
    // A valid form has a choice: "Custom" with no number makes it invalid.
    if (days == null) return;
    final name = (_form.control(_nameControl).value as String?)?.trim() ?? '';
    final selection = _grantableOnly(_selection, state.grantable);
    // A banner left under the question's barrier is read again when the
    // question closes, as news it no longer is.
    _retireFailure();

    final critical = criticalIn(selection, state.grantable);
    final confirmed = critical.isNotEmpty && await _confirmCritical(critical);
    if (!mounted || (critical.isNotEmpty && !confirmed)) return;
    _send((
      name: name,
      selection: selection,
      days: days,
      confirmCritical: confirmed,
    ));
  }

  void _send(_Sent sent) {
    _sent = sent;
    _bloc.add(
      ApiKeyCreateSubmitted(
        name: sent.name,
        selection: sent.selection,
        days: sent.days,
        confirmCritical: sent.confirmCritical,
      ),
    );
  }

  /// Asks about [critical], and completes with whether the user said yes.
  Future<bool> _confirmCritical(List<GrantablePermission> critical) async {
    _asking = true;
    // Given here as well as by a key press, so the question hands focus back
    // to Create for a screen reader's double tap too, which gives it none.
    _createFocus?.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    try {
      return await showCriticalConfirm(context, critical);
    } finally {
      _asking = false;
    }
  }

  /// Once a create ends: see "A Critical permission" and "The secret" on
  /// [ApiKeyCreateScreen].
  void _onCreateEnded(BuildContext context, ApiKeyCreateState state) {
    if (state.created != null) {
      // The form goes in the frame this state builds, and Create with it,
      // focus too. The title takes it first, so it never falls back to
      // whatever the page had focused before.
      _heading.requestFocus();
      // The page may be scrolled far down a long form, to Create. The
      // panel starts from its top, where the key is.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
      return;
    }
    final sent = _sent;
    if (sent == null || !_asksForServer(state.failure, sent)) return;
    // A route the router is taking away is no place to ask from: the
    // question would open over the page the user went to.
    if (ModalRoute.isActiveOf(context) == false) return;
    unawaited(_confirmForServer(sent, state.grantable));
  }

  /// Whether [failure] is the server asking for the confirmation [sent]
  /// went without, rather than a failure to show.
  static bool _asksForServer(ApiKeyFailure? failure, _Sent sent) =>
      failure?.reason == ApiKeyFailureReason.criticalNeedsConfirmation &&
      !sent.confirmCritical;

  /// Asks what the server asked for, with the permissions as [grantable]
  /// has them now, and sends [sent] again, confirmed, on a yes.
  Future<void> _confirmForServer(
    _Sent sent,
    List<GrantablePermission> grantable,
  ) async {
    final selection = _grantableOnly(sent.selection, grantable);
    final confirmed = await _confirmCritical(
      criticalIn(selection, grantable),
    );
    if (!mounted) return;
    if (!confirmed) {
      // Nothing more is sent, and nothing failed: the form is as it was.
      _retireFailure();
      return;
    }
    _send((
      name: sent.name,
      selection: selection,
      days: sent.days,
      confirmCritical: true,
    ));
  }

  /// A pop the page refused: see "The secret" on [ApiKeyCreateScreen].
  ///
  /// Read from the bloc, not the last build: `canPop` is only as new as the
  /// last frame, and Back can land between an answer and the frame that
  /// draws it.
  void _onPopRefused() {
    final state = _bloc.state;
    if (state.created != null) {
      unawaited(_askThenLeave());
      return;
    }
    // On its way: leaving now would lose the secret with the page.
    if (state.submitting) return;
    // It failed since the last frame, so nothing holds the page.
    Navigator.of(context).pop();
  }

  Future<void> _askThenLeave() async {
    if (await _askToLeave() && mounted) _leave();
  }

  /// What the route's holder is told when it asks to take the route away
  /// without a pop: see "The secret" on [ApiKeyCreateScreen].
  FutureOr<bool> _mayLeave() {
    // A session that has ended takes its pages with it, and asks nothing.
    if (!(_session?.isLive ?? true)) return true;
    // Done, or Leave after a refused pop: the user has answered already.
    if (_leaving) return true;
    final state = _bloc.state;
    if (state.created != null) return _askToLeave();
    // On its way: held, as a pop is, or the secret is lost with the page.
    return !state.submitting;
  }

  /// Asks whether to leave the secret, and completes with whether the user
  /// chose to. One question at a time: asked again while it is open, it
  /// answers with the open one's answer.
  Future<bool> _askToLeave() => _leaveQuestion ??= _showLeaveQuestion();

  Future<bool> _showLeaveQuestion() async {
    if (!_leaveAsked) setState(() => _leaveAsked = true);
    try {
      return await _LeaveDialog.show(context);
    } finally {
      _leaveQuestion = null;
    }
  }

  /// Leaves the page, by Done or by Leave after a refused pop. A plain
  /// pop, which the page's refusal doesn't stand in the way of: the user
  /// has been asked, or has said they are done. What then takes the route
  /// is not asked about it again.
  void _leave() {
    _leaving = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => BlocProvider<ApiKeyCreateBloc>.value(
    value: _bloc,
    child: BlocListener<ApiKeyCreateBloc, ApiKeyCreateState>(
      listenWhen: (previous, current) =>
          previous.submitting && !current.submitting,
      listener: _onCreateEnded,
      child: BlocBuilder<ApiKeyCreateBloc, ApiKeyCreateState>(
        builder: _buildState,
      ),
    ),
  );

  Widget _buildState(BuildContext context, ApiKeyCreateState state) {
    final l10n = ApiKeysLocalizations.of(context);
    final created = state.created;
    final loaded = state.grantableStatus == ApiKeyGrantableStatus.loaded;

    return PopScope<Object?>(
      // Held from the press of Create until the page is left by Done or by
      // Leave. `submitting` gives way to `created` in one state, so there is
      // no frame between them where a pop gets through.
      canPop: !state.submitting && created == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPopRefused();
      },
      child: BgePage(
        title: Focus(
          focusNode: _heading,
          child: Text(
            created == null ? l10n.apiKeyCreateTitle : l10n.apiKeySecretTitle,
          ),
        ),
        scrollController: _scroll,
        // The spinner and the failure sit mid-page, the form and the key at
        // the top.
        centerVertically: created == null && !loaded,
        child: created != null
            ? SecretPanel(
                created: created,
                onDone: _leave,
                announce: !_leaveAsked,
              )
            : switch (state.grantableStatus) {
                ApiKeyGrantableStatus.loading => BgeLoadingState(
                  key: ApiKeyCreateScreen.loadingKey,
                  label: l10n.apiKeyCreateLoading,
                ),
                ApiKeyGrantableStatus.loadFailed => BgeErrorState(
                  key: ApiKeyCreateScreen.failedKey,
                  retryKey: ApiKeyCreateScreen.retryKey,
                  icon: Icons.cloud_off_outlined,
                  title: l10n.apiKeyCreateLoadFailed,
                  body: l10n.apiKeyCreateLoadFailedBody,
                  retryLabel: l10n.apiKeyCreateRetry,
                  onRetry: _retry,
                ),
                ApiKeyGrantableStatus.loaded => _buildForm(
                  context,
                  l10n,
                  state,
                ),
              },
      ),
    );
  }

  Widget _buildForm(
    BuildContext context,
    ApiKeysLocalizations l10n,
    ApiKeyCreateState state,
  ) {
    final offline = BgeConnectivityScope.offlineOf(context);
    final submitting = state.submitting;
    final sent = _sent;
    // Unconfirmed, the server's Critical refusal is its question, which the
    // dialog asks: a banner under that dialog would say it twice.
    final failure = sent != null && _asksForServer(state.failure, sent)
        ? null
        : state.failure;
    final bySlug = {
      for (final permission in state.grantable) permission.slug: permission,
    };
    final failureMessage = failure == null
        ? null
        : apiKeyFailureMessage(l10n, failure, grantable: bySlug);

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeTextField(
            key: ApiKeyCreateScreen.nameKey,
            formControlName: _nameControl,
            label: l10n.apiKeyNameLabel,
            readOnly: submitting,
            validationMessages: {
              ValidationMessage.required: (_) => l10n.apiKeyNameRequired,
              ApiKeyNameErrors.tooLong: (_) => l10n.apiKeyNameTooLong(
                ApiKeyRemoteDataSource.maxNameLength,
              ),
              ApiKeyNameErrors.nul: (_) => l10n.apiKeyNameNul,
            },
          ),
          const BgeGap.lg(),
          Semantics(
            header: true,
            child: Text(
              l10n.apiKeyPermissionsHeading,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const BgeGap.sm(),
          ScopePicker(
            grantable: state.grantable,
            selection: _grantableOnly(_selection, state.grantable),
            onChanged: _onPicked,
            readOnly: submitting,
            refusedSlug: failure?.slug,
            refusedMessage: failureMessage,
            announceNoneWarning: _picksChanged,
          ),
          const BgeGap.lg(),
          ExpiryControl(
            days: _days,
            onChanged: _onDays,
            label: l10n.apiKeyExpiryCreateLabel,
            customDaysName: _customDaysControl,
            readOnly: submitting,
          ),
          const BgeGap.lg(),
          BgeFormActions(
            failure: failureMessage == null
                ? null
                : BgeFormFailure(
                    key: ApiKeyCreateScreen.errorKey,
                    // Some messages give only a cause: "Couldn't reach the
                    // server" never says what failed.
                    title: l10n.apiKeyCreateFailedTitle,
                    message: failureMessage,
                  ),
            action: BgeOnlineOnly(
              child: ApiKeySubmitButton(
                buttonKey: ApiKeyCreateScreen.submitKey,
                label: l10n.apiKeyCreateSubmit,
                busyLabel: l10n.apiKeyCreateSubmitting,
                busy: submitting,
                onPressed: offline ? null : () => unawaited(_submit()),
                onFocusNode: (node) => _createFocus = node,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks before the page that shows a new key's secret is left by Back
/// (#1028). Stay, a tap outside and Back all keep the page.
class _LeaveDialog extends StatelessWidget {
  const _LeaveDialog();

  /// Shows the question over [context]'s page, and completes with whether
  /// the user chose to leave.
  static Future<bool> show(BuildContext context) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (_) => const _LeaveDialog(),
    );
    return leave ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);

    return AlertDialog(
      scrollable: true,
      title: Text(l10n.apiKeyLeaveTitle),
      content: Text(l10n.apiKeyLeaveBody),
      actions: [
        TextButton(
          key: ApiKeyCreateScreen.leaveStayKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.apiKeyLeaveStay),
        ),
        TextButton(
          key: ApiKeyCreateScreen.leaveConfirmKey,
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.apiKeyLeaveConfirm),
        ),
      ],
    );
  }
}
