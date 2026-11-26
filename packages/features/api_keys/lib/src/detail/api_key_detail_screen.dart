import 'dart:async';

import 'package:api_keys/l10n/api_keys_localizations.dart';
import 'package:api_keys/src/detail/api_key_detail_bloc.dart';
import 'package:api_keys/src/detail/api_key_detail_event.dart';
import 'package:api_keys/src/detail/api_key_detail_state.dart';
import 'package:api_keys/src/detail/scope_edit.dart';
import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:api_keys/src/form/api_key_name_control.dart';
import 'package:api_keys/src/widgets/api_key_facts.dart';
import 'package:api_keys/src/widgets/api_key_scope_list.dart';
import 'package:api_keys/src/widgets/api_key_submit_button.dart';
import 'package:api_keys/src/widgets/critical_confirm_dialog.dart';
import 'package:api_keys/src/widgets/delete_key_dialog.dart';
import 'package:api_keys/src/widgets/expiry_control.dart';
import 'package:api_keys/src/widgets/scope_picker.dart';
import 'package:api_keys/src/widgets/scope_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One of the signed-in user's API keys, on its own page (#1028): its name,
/// the start of its secret, when it was made, when it expires and when it was
/// last used; a form that renames the key, changes its permissions or sets a
/// new expiry; an Enabled switch; and Delete.
///
/// Online only, as the key list is: the key and the permissions the user may
/// grant are read from the server when the page opens, and nothing is
/// stored. A 404 says the key no longer exists, with a way back.
///
/// The name heads the page as well as the app bar, which cuts a long one
/// short at 200% text on a phone.
///
/// ## The form
///
/// It starts from the key: its name, every permission it holds listed with
/// what it allows and its risk ([ApiKeyScopeList]), and no new expiry
/// ([ExpiryControl], "Set a new expiry", with "Keep current" chosen), then
/// Save changes. "Keep current" takes back an expiry picked by mistake.
///
/// "Change permissions", under the list, swaps it in place for a
/// [ScopePicker] ticked as the key holds them, and focus waits on the
/// permissions' heading. "Keep permissions as they were", under the picker,
/// swaps the list back and the picks with it. A save that goes through
/// shows the list again, as the server answered it. While a write is on its
/// way, either button is read-only, as the fields are.
///
/// Save sends only what the user changed, so a key that holds a permission
/// its owner may no longer give can still be renamed:
///
/// - the name, once trimmed, when it differs from the key's. A key made
///   outside the app can have no name, and needn't be given one: left empty,
///   its name is unchanged, and never sent empty;
/// - the permissions, only while the picker shows, and when the picks
///   differ from those the key holds that the user may still give, compared
///   by permission and record. They are the key's whole new list: the picks,
///   and every scope the key holds limited to one record, as it was. A
///   permission the user may no longer give is not sent, and its row says
///   saving removes it;
/// - the expiry, when one is picked and "Keep current" isn't.
///
/// With nothing changed, Save sends nothing and says so, each time it is
/// pressed. A press the form refuses moves focus to the first field at
/// fault. A save that goes through says "Saved", the page shows the key as
/// the server answered it, and the form starts from that again.
///
/// The permissions the user may give also say what each held one allows.
/// When they can't be read, the key's permissions are shown by their codes,
/// as facts, with no "Change permissions": they can't be changed until the
/// page is opened again. Renaming and a new expiry still work, and never
/// send permissions.
///
/// ## A Critical permission
///
/// A save that gives the key a Critical permission it doesn't hold yet asks
/// first ([showCriticalConfirm]), naming those. Keeping one it holds asks
/// nothing, as the server matches by permission. Cancel sends nothing; only
/// a yes sends `confirmCritical`.
///
/// The server can find one the page did not, when the permissions changed
/// after the page read them. It refuses the unconfirmed save, the bloc reads
/// the permissions again, and the same question comes up with what is
/// Critical now. A yes sends the save once more, confirmed. If the server
/// refuses that one the same way, it is a failure like any other, and
/// nothing asks again. A stale sign-in is answered in words, with no action
/// (#1113).
///
/// ## Writes
///
/// Save, Enabled and Delete each go straight to the server, so offline each
/// is disabled and says why (#49): the switch in its own label, Save and
/// Delete in their hints and a note under each. The form can still be filled
/// in offline.
///
/// One write is out at a time. The control that started it stays enabled and
/// ignores presses, so it keeps focus (STYLE_GUIDE §5); the others are
/// disabled, since no press of their own made them wait. While any is out
/// the form's fields are read-only, not disabled, so each keeps its place in
/// the focus order, and a save sends the form as it was pressed.
///
/// - **Save** says it is saving, in a live region while it is.
/// - **Enabled** asks for nothing: re-enabling a key needs no confirmation.
///   It shows the key as the server last answered it, and a bar above it,
///   read out as "Saving…", says a change is on its way.
/// - **Delete** asks first, naming the key. Opening the dialog retires a
///   standing outcome, so no stale banner sits under its barrier to be read
///   again when it closes. Delete takes focus as it is pressed, which a
///   screen reader's double tap doesn't give it, so the dialog hands focus
///   back to it when it closes, as the Critical question does to Save. While
///   the delete is out its label says it is deleting.
///
/// A save's outcome shows in a [BgeInlineBanner] directly above Save, until
/// the user edits the form or another write starts. A failed toggle or
/// delete shows directly above its control, until the next write starts or
/// Delete's dialog opens: an edit to the form is no answer to it. A key the
/// server finds gone takes the page to the gone state, with focus on the
/// page's title, since the controls went with the key.
///
/// ## Leaving
///
/// A delete that goes through says "Deleted {name}" in a SnackBar, on the
/// messenger above the route, and pops the page. The page goes on drawing
/// the key meanwhile, so nothing flashes on the way out.
///
/// The page saves and then leaves, so it owns its bloc past the route
/// (STYLE_GUIDE, "a screen that saves and then leaves"; #464). It makes the
/// bloc when it opens, with the [sessionLease] of the session [remote] came
/// from, and closes it through `closeWhenSettled` in `dispose`. A write the
/// user walked away from is said once it ends, in a SnackBar on the page
/// they went to: deleted, saved, enabled, disabled, or why it failed. So is
/// one that ends while the route is still leaving, and that never navigates.
/// Nothing is said once the session has ended (#694).
///
/// ## Another key
///
/// The router keeps this page when only the id changes, so a new [id] makes
/// a new bloc and form, and the old key's late answer is said as if its page
/// had gone.
class ApiKeyDetailScreen extends StatelessWidget {
  const ApiKeyDetailScreen({
    required this.remote,
    required this.id,
    required this.sessionLease,
    super.key,
  });

  static const Key loadingKey = Key('api_key_detail.loading');
  static const Key failedKey = Key('api_key_detail.failed');
  static const Key retryKey = Key('api_key_detail.retry');
  static const Key goneKey = Key('api_key_detail.gone');
  static const Key backKey = Key('api_key_detail.back');

  /// On the Enabled switch's `SwitchListTile`.
  static const Key enabledKey = Key('api_key_detail.enabled');

  /// On Delete's `TextButton`.
  static const Key deleteKey = Key('api_key_detail.delete');

  /// The banner above the switch when enabling or disabling failed.
  static const Key toggleFailedKey = Key('api_key_detail.toggle_failed');

  /// The banner above Delete when deleting failed.
  static const Key deleteFailedKey = Key('api_key_detail.delete_failed');

  /// On the name's field.
  static const Key nameKey = Key('api_key_detail.name');

  /// On Save's `FilledButton`.
  static const Key saveKey = Key('api_key_detail.save');

  /// The banner above Save once a save has gone through.
  static const Key savedKey = Key('api_key_detail.saved');

  /// The banner above Save when it was pressed with nothing changed.
  static const Key nothingToSaveKey = Key('api_key_detail.nothing_to_save');

  /// The banner above Save when a save failed.
  static const Key saveFailedKey = Key('api_key_detail.save_failed');

  /// On "Change permissions", under the key's permissions.
  static const Key changeScopesKey = Key('api_key_detail.change_scopes');

  /// On "Keep permissions as they were", under the picker.
  static const Key keepScopesKey = Key('api_key_detail.keep_scopes');

  final ApiKeyRemoteDataSource remote;

  /// The key to show.
  final String id;

  /// The user session [remote] came from. A write that ends after the page
  /// has gone is said only while it is live (#694).
  final SessionLease sessionLease;

  @override
  Widget build(BuildContext context) => _ApiKeyDetail(
    // go_router keeps this page when only the id changes; the key makes a
    // new id a new bloc rather than the old key under the new one's URL.
    key: ValueKey<String>(id),
    screen: this,
  );
}

/// A save as the page sent it, kept to send again once the server's
/// question is answered, and to tell that question from a failure.
typedef _Sent = ({
  String? name,
  List<ApiKeyScope>? scopes,
  int? days,
  bool confirmCritical,
});

/// The page for one key, its form, and its bloc, which outlives the route.
class _ApiKeyDetail extends StatefulWidget {
  const _ApiKeyDetail({required this.screen, super.key});

  final ApiKeyDetailScreen screen;

  @override
  State<_ApiKeyDetail> createState() => _ApiKeyDetailState();
}

class _ApiKeyDetailState extends State<_ApiKeyDetail> {
  static const _nameControl = 'name';
  static const _customDaysControl = 'customDays';

  /// Held here rather than by a `BlocProvider`, which would close it with
  /// the route: a write still out then would never say how it ended. See
  /// [dispose].
  late final ApiKeyDetailBloc _bloc;

  /// The lease of the session the bloc's remote came from, taken when the
  /// bloc is made, since [dispose] can't trust a later build's.
  late final SessionLease _session;

  /// The messenger above the route, which says a bar only while [_session] is
  /// live, and this page's strings, captured while the page is mounted: a
  /// write that ends after it is gone is said with them, and [dispose] can't
  /// look them up.
  late final SessionMessenger _messenger = SessionMessenger(
    sessionIsLive: () => _session.isLive,
  );
  late ApiKeysLocalizations _l10n;

  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop. Where focus goes when the control that had it goes.
  final FocusNode _heading = FocusNode(
    debugLabel: 'API key heading',
    skipTraversal: true,
  );

  /// Delete's focus node, owned by its [BgeInertButton] and taken from its
  /// builder, so a press can give Delete focus before its dialog opens.
  FocusNode? _deleteFocus;

  /// Save's focus node, taken the same way, for the Critical question.
  FocusNode? _saveFocus;

  /// Whether the picker shows in place of the key's permissions: from
  /// "Change permissions" until "Keep permissions as they were" or a save
  /// that goes through.
  bool _changingScopes = false;

  /// On the permissions' heading, which takes focus only when sent there:
  /// where "Change permissions" leaves it, as the button goes with the list.
  final FocusNode _permissionsHeading = FocusNode(
    debugLabel: 'API key permissions heading',
    skipTraversal: true,
  );

  /// "Change permissions"' focus node, taken from its builder, which
  /// "Keep permissions as they were" hands focus back to as it goes.
  FocusNode? _changeScopesFocus;

  /// The form's name, and the expiry's custom field: part of this form, so a
  /// bad number there makes the form invalid and is what a refused Save
  /// focuses. Started from the key once it has loaded, and again from what
  /// each save answered.
  late final FormGroup _form = FormGroup({
    _nameControl: apiKeyNameControl(),
    _customDaysControl: expiryCustomDaysControl(),
  });
  StreamSubscription<Object?>? _edits;

  /// The permissions picked. They start as those the key holds that the
  /// user may still give.
  PickedScopes _picks = const PickedScopes([]);

  /// Whether the user has changed the picks since the form last started,
  /// which makes the picker's nothing-picked warning news rather than how
  /// the key is.
  bool _picksChanged = false;

  /// The new expiry chosen, in days. Null while none is, which keeps the
  /// key's own, and while "Custom" holds no valid number, which makes the
  /// form invalid.
  int? _days;

  /// The last save sent.
  _Sent? _sent;

  /// Whether the Critical question is open, so nothing opens a second.
  bool _asking = false;

  /// Counts the presses of Save that found nothing to save. Each builds the
  /// banner anew, so a screen reader hears it arrive again, as it would not
  /// from a banner that stayed.
  int _nothingToSave = 0;

  @override
  void initState() {
    super.initState();
    final screen = widget.screen;
    _session = screen.sessionLease;
    _bloc = ApiKeyDetailBloc(screen.remote, id: screen.id)
      ..add(const ApiKeyDetailRequested());
    // What a save said describes the form as it was, so an edit retires it.
    // The picks and the expiry's chips, which are no controls of the form,
    // do the same where they change. Starting the form again is no edit: it
    // leaves the form pristine, where the user's typing makes it dirty.
    _edits = _form.valueChanges.listen((_) {
      if (_form.dirty) _retireSaveOutcome();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger.attach(context);
    _l10n = ApiKeysLocalizations.of(context);
  }

  @override
  void dispose() {
    // Gone with a write out: it ends, is said while the session lives, and
    // the bloc closes then. Otherwise the page has shown whatever there was,
    // and the bloc closes now.
    unawaited(
      closeWhenSettled<ApiKeyDetailState>(
        current: _bloc.state,
        states: _bloc.stream,
        underWay: (state) => state.writing != null,
        outcomeOf: _lateMessage,
        say: _messenger.say,
        close: _bloc.close,
      ),
    );
    unawaited(_edits?.cancel());
    _form.dispose();
    _heading.dispose();
    _permissionsHeading.dispose();
    super.dispose();
  }

  /// How a write ended, in words for a SnackBar once the user has left the
  /// page: deleted, saved, enabled or disabled, or why it failed, since the
  /// banner went with the page. Nothing for a key found gone.
  String? _lateMessage(ApiKeyDetailState state) {
    final key = state.key;
    if (key == null) return null;
    final name = apiKeyNameOf(_l10n, key);
    return switch (state.outcome) {
      ApiKeyDetailDeleted() => _l10n.apiKeyDeleted(name),
      ApiKeyDetailSaved() => _l10n.apiKeySavedDone(name),
      ApiKeyDetailFailed(:final failure, :final write) =>
        _l10n.apiKeyFailedLate(
          _failedTitle(_l10n, write, key),
          apiKeyFailureMessage(_l10n, failure, grantable: state.grantable),
        ),
      // Said as Save was pressed, with nothing sent: no write ends with it.
      ApiKeyDetailNothingToSave() => null,
      // A toggle that went through: the key is as the server answered.
      null =>
        key.enabled
            ? _l10n.apiKeyEnabledDone(name)
            : _l10n.apiKeyDisabledDone(name),
    };
  }

  /// Once the key has loaded: the form starts from it.
  void _onLoaded(BuildContext context, ApiKeyDetailState state) =>
      _startForm(state);

  /// Once a write ends: see "Leaving" and "A Critical permission" on
  /// [ApiKeyDetailScreen].
  ///
  /// A route already on its way out, by its back button say, says how the
  /// write ended, a failure too, and goes nowhere: popping then would take
  /// the page beneath with it, and a question would open over the page the
  /// user went to. By `dispose` the write has ended, so `closeWhenSettled`
  /// says nothing more.
  void _onWriteEnded(BuildContext context, ApiKeyDetailState state) {
    final route = ModalRoute.of(context);
    if (route != null && !route.isActive) {
      _messenger.say(_lateMessage(state));
      return;
    }
    if (state.status == ApiKeyDetailStatus.gone) {
      // The form, the switch and Delete went with the key, focus too, so it
      // waits on the title.
      _heading.requestFocus();
      return;
    }
    if (state.deleted) {
      _leaveDeleted(context, route, state);
      return;
    }
    final outcome = state.outcome;
    final sent = _sent;
    if (outcome is ApiKeyDetailSaved) {
      // The key is as the server answered it: nothing differs any more.
      _startForm(state);
    } else if (outcome is ApiKeyDetailFailed &&
        outcome.write == ApiKeyWrite.save &&
        sent != null &&
        _asksForServer(outcome.failure, sent)) {
      unawaited(_confirmForServer(sent));
    }
  }

  /// A delete that went through: the page leaves, and says so on the page
  /// beneath.
  void _leaveDeleted(
    BuildContext context,
    ModalRoute<Object?>? route,
    ApiKeyDetailState state,
  ) {
    // The page stays live while the delete is out, so something can be
    // open over it when the answer lands, and a pop would take whatever is
    // on top. That goes first.
    if (route != null && !route.isCurrent) {
      Navigator.of(context).popUntil((r) => r == route);
    }
    // The messenger is above the route, so the bar outlives it and shows on
    // the page it leaves for.
    _messenger.say(_lateMessage(state));
    Navigator.of(context).maybePop();
  }

  /// Starts the form from [state]'s key, as it loaded or as a save answered
  /// it: its name, no new expiry, and the permissions it holds that the user
  /// may still give, those limited to one record among them.
  ///
  /// The form's reset clears a custom expiry with the days: the expiry
  /// control ends "Custom" on it (see [ExpiryControl]). The reset leaves the
  /// form pristine, so it is no edit, and retires nothing.
  void _startForm(ApiKeyDetailState state) {
    final key = state.key;
    if (key == null) return;
    final grantable = state.grantable;
    // A key made outside the app can have no name. It needn't be given one
    // for another edit to save (#1028). Checked again now, as a reset to the
    // value the control holds checks nothing; quietly, as the reset below
    // says what changed, and is no edit.
    _form
        .control(_nameControl)
        .setValidators(
          apiKeyNameValidators(required: key.name != null),
          autoValidate: true,
          emitEvent: false,
        );
    setState(() {
      _form.reset(value: {_nameControl: key.name});
      _days = null;
      _picks = PickedScopes(
        grantable == null ? const [] : heldGrantable(key, grantable),
      );
      _picksChanged = false;
      // Loaded or saved, the key's permissions are what the page lists.
      _changingScopes = false;
    });
  }

  /// "Change permissions": the picker takes the list's place, starting from
  /// what the key holds, and focus waits on the heading it sits under.
  void _changeScopes() {
    setState(() => _changingScopes = true);
    _permissionsHeading.requestFocus();
  }

  /// "Keep permissions as they were": the list comes back, and the picks go
  /// back to what the key holds, so no save sends permissions.
  void _keepScopes(ApiKey key, Map<String, GrantablePermission> grantable) {
    setState(() {
      _changingScopes = false;
      _picks = PickedScopes(heldGrantable(key, grantable));
      _picksChanged = false;
    });
    // A save's failure may name a permission the picks no longer hold.
    _retireSaveOutcome();
    // "Change permissions" comes back where this button was.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _changeScopesFocus?.requestFocus();
    });
  }

  /// Retires what the last save said, once the form no longer holds what it
  /// was said of. A failed toggle or delete is about its own control, and
  /// stays.
  void _retireSaveOutcome() {
    if (_bloc.isClosed) return;
    final ofSave = switch (_bloc.state.outcome) {
      ApiKeyDetailSaved() || ApiKeyDetailNothingToSave() => true,
      ApiKeyDetailFailed(:final write) => write == ApiKeyWrite.save,
      ApiKeyDetailDeleted() || null => false,
    };
    if (ofSave) _bloc.add(const ApiKeyDetailOutcomeCleared());
  }

  void _onPicked(ScopeSelection selection) {
    // The preset is not offered on a key that exists.
    if (selection is! PickedScopes) return;
    setState(() {
      _picks = selection;
      _picksChanged = true;
    });
    _retireSaveOutcome();
  }

  void _onDays(int? days) {
    setState(() => _days = days);
    _retireSaveOutcome();
  }

  Future<void> _save() async {
    final state = _bloc.state;
    final key = state.key;
    // Saving is a direct write (#49). Returning before the validity check
    // keeps an offline press from marking the form touched.
    if (_asking ||
        key == null ||
        state.writing != null ||
        state.deleted ||
        BgeConnectivityScope.offlineOf(context)) {
      return;
    }
    if (!_form.valid) {
      _form.rejectSubmit();
      return;
    }
    final typed = (_form.control(_nameControl).value as String?)?.trim() ?? '';
    // An unnamed key left unnamed keeps no name: an empty one is never sent.
    final name = typed.isEmpty && key.name == null ? null : typed;
    final grantable = state.grantable;
    // Unread, the permissions are not offered, and never sent. Listed, they
    // are as the key holds them.
    final scopes = grantable == null || !_changingScopes
        ? null
        : scopesToSend(key, grantable, _picks.scopes);
    // A banner left under the question's barrier is read again when the
    // question closes, as news it no longer is.
    _bloc.add(const ApiKeyDetailOutcomeCleared());

    final critical = scopes == null || grantable == null
        ? const <GrantablePermission>[]
        : newCritical(key, scopes, grantable);
    final confirmed = critical.isNotEmpty && await _confirmCritical(critical);
    if (!mounted || (critical.isNotEmpty && !confirmed)) return;
    _send((
      name: name == key.name ? null : name,
      scopes: scopes,
      // A valid form with no expiry chosen keeps the key's.
      days: _days,
      confirmCritical: confirmed,
    ));
  }

  void _send(_Sent sent) {
    _sent = sent;
    _bloc.add(
      ApiKeySaveRequested(
        name: sent.name,
        scopes: sent.scopes,
        expiresInDays: sent.days,
        confirmCritical: sent.confirmCritical,
      ),
    );
  }

  /// Asks about [critical], and completes with whether the user said yes.
  Future<bool> _confirmCritical(List<GrantablePermission> critical) async {
    _asking = true;
    // Given here as well as by a key press, so the question hands focus back
    // to Save for a screen reader's double tap too, which gives it none.
    _saveFocus?.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    try {
      return await showCriticalConfirm(context, critical);
    } finally {
      _asking = false;
    }
  }

  /// Whether [failure] is the server asking for the confirmation [sent]
  /// went without, rather than a failure to show.
  static bool _asksForServer(ApiKeyFailure failure, _Sent sent) =>
      failure.reason == ApiKeyFailureReason.criticalNeedsConfirmation &&
      !sent.confirmCritical;

  /// Asks what the server asked for, with the permissions as the bloc read
  /// them again, and sends [sent] once more, confirmed, on a yes.
  Future<void> _confirmForServer(_Sent sent) async {
    final state = _bloc.state;
    final key = state.key;
    final grantable = state.grantable;
    if (key == null) return;
    final sentScopes = sent.scopes;
    // A permission the list read again no longer has can't be given: its
    // row has gone, so it isn't sent again unseen.
    final scopes = sentScopes == null || grantable == null
        ? sentScopes
        : [
            for (final scope in sentScopes)
              if (grantable.containsKey(scope.slug)) scope,
          ];
    final confirmed = await _confirmCritical(
      scopes == null || grantable == null
          ? const []
          : newCritical(key, scopes, grantable),
    );
    if (!mounted) return;
    if (!confirmed) {
      // Nothing more is sent, and nothing failed: the form is as it was.
      _bloc.add(const ApiKeyDetailOutcomeCleared());
      return;
    }
    _send((
      name: sent.name,
      scopes: scopes,
      days: sent.days,
      confirmCritical: true,
    ));
  }

  void _retry() {
    // Try again goes as the read starts, and would take focus with it.
    _heading.requestFocus();
    _bloc.add(const ApiKeyDetailRequested());
  }

  Future<void> _delete(String name) async {
    // Given here as well as by a key press, so the dialog hands focus back
    // to Delete for a screen reader's double tap too, which gives it none.
    _deleteFocus?.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    // A banner left under the dialog's barrier is read again when the dialog
    // closes, as news it no longer is.
    _bloc.add(const ApiKeyDetailOutcomeCleared());
    final confirmed = await DeleteKeyDialog.show(context, name: name);
    if (!confirmed || !mounted) return;
    _bloc.add(const ApiKeyDeleteRequested());
  }

  @override
  Widget build(BuildContext context) => BlocProvider<ApiKeyDetailBloc>.value(
    value: _bloc,
    child: MultiBlocListener(
      listeners: [
        BlocListener<ApiKeyDetailBloc, ApiKeyDetailState>(
          listenWhen: (previous, current) =>
              previous.status != ApiKeyDetailStatus.loaded &&
              current.status == ApiKeyDetailStatus.loaded,
          listener: _onLoaded,
        ),
        BlocListener<ApiKeyDetailBloc, ApiKeyDetailState>(
          listenWhen: (previous, current) =>
              previous.writing != null && current.writing == null,
          listener: _onWriteEnded,
        ),
        // Save retires the banner before it finds nothing again, but both
        // land before the next frame, which would keep the one banner.
        BlocListener<ApiKeyDetailBloc, ApiKeyDetailState>(
          listenWhen: (previous, current) =>
              previous.outcome is! ApiKeyDetailNothingToSave &&
              current.outcome is ApiKeyDetailNothingToSave,
          listener: (_, _) => setState(() => _nothingToSave++),
        ),
      ],
      child: BlocBuilder<ApiKeyDetailBloc, ApiKeyDetailState>(
        builder: _buildState,
      ),
    ),
  );

  Widget _buildState(BuildContext context, ApiKeyDetailState state) {
    final l10n = ApiKeysLocalizations.of(context);
    final key = state.key;

    return BgePage(
      title: Focus(
        focusNode: _heading,
        child: Text(
          key == null ? l10n.apiKeyDetailTitle : apiKeyNameOf(l10n, key),
        ),
      ),
      // The spinner, the failure and gone sit mid-page, the key at the top.
      centerVertically: key == null,
      child: switch (state.status) {
        ApiKeyDetailStatus.loading => BgeLoadingState(
          key: ApiKeyDetailScreen.loadingKey,
          label: l10n.apiKeyDetailLoading,
        ),
        ApiKeyDetailStatus.loadFailed => BgeErrorState(
          key: ApiKeyDetailScreen.failedKey,
          retryKey: ApiKeyDetailScreen.retryKey,
          icon: Icons.cloud_off_outlined,
          title: l10n.apiKeyDetailLoadFailed,
          body: switch (state.loadFailure) {
            // A refusal says why in its own words, the server's where the
            // client has none (#1028).
            final failure?
                when failure.reason != ApiKeyFailureReason.transient =>
              apiKeyFailureMessage(l10n, failure),
            _ => l10n.apiKeyDetailLoadFailedBody,
          },
          retryLabel: l10n.apiKeyDetailRetry,
          onRetry: _retry,
        ),
        ApiKeyDetailStatus.gone => BgeEmptyState(
          key: ApiKeyDetailScreen.goneKey,
          icon: Icons.key_off_outlined,
          title: l10n.apiKeyGoneTitle,
          body: l10n.apiKeyGoneBody,
          action: TextButton(
            key: ApiKeyDetailScreen.backKey,
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(l10n.apiKeyGoneBack),
          ),
        ),
        ApiKeyDetailStatus.loaded => _loaded(context, l10n, state, key!),
      },
    );
  }

  Widget _loaded(
    BuildContext context,
    ApiKeysLocalizations l10n,
    ApiKeyDetailState state,
    ApiKey key,
  ) {
    final offline = BgeConnectivityScope.offlineOf(context);
    final toggling = state.writing == ApiKeyWrite.toggle;
    final saving = state.writing == ApiKeyWrite.save;
    // Deleted, the page is leaving, and still reads as deleting.
    final deleting = state.writing == ApiKeyWrite.delete || state.deleted;
    final failed = switch (state.outcome) {
      final ApiKeyDetailFailed failed => failed,
      _ => null,
    };
    final name = apiKeyNameOf(l10n, key);

    Widget banner(Key bannerKey, ApiKeyDetailFailed failed) => BgeInlineBanner(
      key: bannerKey,
      tone: BgeBannerTone.error,
      // Some messages give only a cause: "Couldn't reach the server" never
      // says what failed.
      title: _failedTitle(l10n, failed.write, key),
      message: apiKeyFailureMessage(
        l10n,
        failed.failure,
        grantable: state.grantable,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Heading(name, style: Theme.of(context).textTheme.headlineSmall),
        const BgeGap.sm(),
        _Facts(apiKey: key, grantable: state.grantable),
        const BgeGap.lg(),
        _editForm(context, l10n, state, key, offline: offline),
        const BgeGap.xl(),
        if (failed?.write == ApiKeyWrite.toggle) ...[
          banner(ApiKeyDetailScreen.toggleFailedKey, failed!),
          const BgeGap.md(),
        ],
        _SavingBar(saving: toggling),
        // Keyed, so it keeps its element and focus as a banner comes and
        // goes above it.
        BgeRowFocusRing(
          key: const ValueKey('api_key_detail.enabled_ring'),
          outsideSides: true,
          builder: (context, row) => SwitchListTile(
            key: ApiKeyDetailScreen.enabledKey,
            focusNode: row.focusNode,
            onFocusChange: row.onFocusChange,
            contentPadding: EdgeInsets.zero,
            // Offline the reason is a second line of the title, so the
            // tile's one node carries it (#49).
            title: BgeOnlineOnlyLabel(l10n.apiKeyEnabledSwitch),
            subtitle: Text(
              key.enabled ? l10n.apiKeyEnabledOn : l10n.apiKeyEnabledOff,
            ),
            // What the server last answered, not what was last pressed: the
            // bar says a change is on its way.
            value: key.enabled,
            // Through its own change it stays enabled and ignores presses,
            // so it keeps focus (STYLE_GUIDE §5).
            onChanged: offline || deleting || saving
                ? null
                : (on) {
                    if (!toggling) {
                      _bloc.add(ApiKeyEnabledChanged(enabled: on));
                    }
                  },
          ),
        ),
        const BgeGap.lg(),
        if (failed?.write == ApiKeyWrite.delete) ...[
          banner(ApiKeyDetailScreen.deleteFailedKey, failed!),
          const BgeGap.md(),
        ],
        BgeOnlineOnly(
          key: const ValueKey('api_key_detail.delete_gate'),
          child: _DeleteButton(
            deleting: deleting,
            onPressed: offline || toggling || saving
                ? null
                : () => unawaited(_delete(name)),
            onFocusNode: (node) => _deleteFocus = node,
          ),
        ),
      ],
    );
  }

  /// The name, the permissions and a new expiry, then Save: see "The form"
  /// on [ApiKeyDetailScreen].
  Widget _editForm(
    BuildContext context,
    ApiKeysLocalizations l10n,
    ApiKeyDetailState state,
    ApiKey key, {
    required bool offline,
  }) {
    // Read-only, not disabled, while any write is on its way (STYLE_GUIDE,
    // "In-flight forms").
    final busy = state.writing != null || state.deleted;
    final saving = state.writing == ApiKeyWrite.save;
    final grantable = state.grantable;
    final outcome = state.outcome;
    final sent = _sent;
    // Unconfirmed, the server's Critical refusal is its question, which the
    // dialog asks: a banner under that dialog would say it twice.
    final failure = switch (outcome) {
      ApiKeyDetailFailed(write: ApiKeyWrite.save, :final failure)
          when sent == null || !_asksForServer(failure, sent) =>
        failure,
      _ => null,
    };
    final failureMessage = failure == null
        ? null
        : apiKeyFailureMessage(l10n, failure, grantable: grantable);

    return ReactiveForm(
      formGroup: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          BgeTextField(
            key: ApiKeyDetailScreen.nameKey,
            formControlName: _nameControl,
            label: l10n.apiKeyNameLabel,
            readOnly: busy,
            validationMessages: {
              ValidationMessage.required: (_) => l10n.apiKeyNameRequired,
              ApiKeyNameErrors.tooLong: (_) => l10n.apiKeyNameTooLong(
                ApiKeyRemoteDataSource.maxNameLength,
              ),
              ApiKeyNameErrors.nul: (_) => l10n.apiKeyNameNul,
            },
          ),
          const BgeGap.lg(),
          Focus(
            focusNode: _permissionsHeading,
            child: _Heading(
              l10n.apiKeyPermissionsHeading,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const BgeGap.sm(),
          if (grantable == null) ...[
            // What each allows is unknown, so the picker has no rows to
            // offer: the key's permissions show as facts, by their codes.
            ApiKeyScopeList(scopes: key.scopes, grantable: null),
            const BgeGap.sm(),
            Text(l10n.apiKeyScopesNotEditable),
          ] else if (!_changingScopes) ...[
            // Every permission the key holds, with what it allows and its
            // risk (#1028). Unchanged while listed, so a save sends none.
            ApiKeyScopeList(scopes: key.scopes, grantable: grantable),
            const BgeGap.sm(),
            _ScopesSwap(
              buttonKey: ApiKeyDetailScreen.changeScopesKey,
              label: l10n.apiKeyScopesChange,
              readOnly: busy,
              onPressed: _changeScopes,
              onFocusNode: (node) => _changeScopesFocus = node,
            ),
          ] else ...[
            ScopePicker(
              grantable: grantable.values.toList(),
              selection: _picks,
              held: key.scopes,
              offerEverything: false,
              onChanged: _onPicked,
              readOnly: busy,
              refusedSlug: failure?.slug,
              refusedMessage: failureMessage,
              announceNoneWarning: _picksChanged,
            ),
            const BgeGap.sm(),
            _ScopesSwap(
              buttonKey: ApiKeyDetailScreen.keepScopesKey,
              label: l10n.apiKeyScopesKeep,
              readOnly: busy,
              onPressed: () => _keepScopes(key, grantable),
            ),
          ],
          const BgeGap.lg(),
          ExpiryControl(
            days: _days,
            onChanged: _onDays,
            label: l10n.apiKeyExpiryEditLabel,
            customDaysName: _customDaysControl,
            keepLabel: l10n.apiKeyExpiryKeep,
            readOnly: busy,
          ),
          const BgeGap.lg(),
          if (outcome is ApiKeyDetailSaved) ...[
            BgeInlineBanner(
              key: ApiKeyDetailScreen.savedKey,
              tone: BgeBannerTone.success,
              message: l10n.apiKeySaved,
            ),
            const BgeGap.md(),
          ],
          if (outcome is ApiKeyDetailNothingToSave) ...[
            KeyedSubtree(
              key: ValueKey(('nothing to save', _nothingToSave)),
              child: BgeInlineBanner(
                key: ApiKeyDetailScreen.nothingToSaveKey,
                message: l10n.apiKeyNothingToSave,
              ),
            ),
            const BgeGap.md(),
          ],
          BgeFormActions(
            failure: failureMessage == null
                ? null
                : BgeFormFailure(
                    key: ApiKeyDetailScreen.saveFailedKey,
                    // Some messages give only a cause: "Couldn't reach the
                    // server" never says what failed.
                    title: _failedTitle(l10n, ApiKeyWrite.save, key),
                    message: failureMessage,
                  ),
            action: BgeOnlineOnly(
              child: ApiKeySubmitButton(
                buttonKey: ApiKeyDetailScreen.saveKey,
                label: l10n.apiKeySaveSubmit,
                busyLabel: l10n.apiKeySaveSubmitting,
                busy: saving,
                // While another write is out it waits, disabled: no press of
                // its own made it so.
                onPressed: offline || (busy && !saving)
                    ? null
                    : () => unawaited(_save()),
                onFocusNode: (node) => _saveFocus = node,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What failed, by the [write] and the [key] it was sent for. A failed toggle
/// leaves the key as it was, so an enabled key failed to be disabled.
String _failedTitle(
  ApiKeysLocalizations l10n,
  ApiKeyWrite write,
  ApiKey key,
) {
  final name = apiKeyNameOf(l10n, key);
  return switch (write) {
    ApiKeyWrite.toggle =>
      key.enabled
          ? l10n.apiKeyDisableFailed(name)
          : l10n.apiKeyEnableFailed(name),
    ApiKeyWrite.delete => l10n.apiKeyDeleteFailed(name),
    ApiKeyWrite.save => l10n.apiKeySaveFailed(name),
  };
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: style),
  );
}

/// The key's facts, a line each, as its row on the list gives them, with
/// when it was made. Whether it is enabled is the switch's to say.
class _Facts extends StatelessWidget {
  const _Facts({required this.apiKey, required this.grantable});

  final ApiKey apiKey;
  final Map<String, GrantablePermission>? grantable;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final facts = apiKeyFactLines(l10n, apiKey);
    final start = facts.start;
    final scopes = apiKey.scopes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (start != null) Text(start),
        // With none, the permissions below say the key works nowhere.
        if (scopes.isNotEmpty) Text(scopeSummary(l10n, scopes, grantable)),
        Text(l10n.apiKeyCreated(apiKey.createdAt.toLocal())),
        Text(facts.expiry),
        Text(facts.lastUsed),
      ],
    );
  }
}

/// The busy cue while enabling or disabling is on its way, read out as
/// "Saving…".
///
/// Its slot keeps its height whether the bar shows or not, so the switch
/// doesn't move under the pointer that just pressed it.
class _SavingBar extends StatelessWidget {
  const _SavingBar({required this.saving});

  final bool saving;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: BgeTokens.of(context).spaceXs,
    child: saving
        ? Semantics(
            liveRegion: true,
            label: ApiKeysLocalizations.of(context).apiKeySaving,
            child: const ExcludeSemantics(child: LinearProgressIndicator()),
          )
        : null,
  );
}

/// "Change permissions" or "Keep permissions as they were", which swap the
/// key's permissions and the picker in place (#1028).
///
/// Read-only while a write is on its way, as the form's fields are
/// (STYLE_GUIDE, "In-flight forms"): it stays enabled and in the focus
/// order, reads as not available, and a press does nothing. Neither is a
/// write, so neither waits for a connection.
class _ScopesSwap extends StatelessWidget {
  const _ScopesSwap({
    required this.buttonKey,
    required this.label,
    required this.readOnly,
    required this.onPressed,
    this.onFocusNode,
  });

  final Key buttonKey;
  final String label;

  final bool readOnly;
  final VoidCallback onPressed;

  /// Given the button's focus node as it is built.
  final ValueChanged<FocusNode>? onFocusNode;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: BgeInertButton(
      inert: readOnly,
      label: label,
      onPressed: onPressed,
      builder: (context, focusNode, onPressed) {
        onFocusNode?.call(focusNode);
        // At 320dp and 200% text the label wraps, and a Material button is
        // clipped to its shape: the theme's stadium would cut into the
        // wrapped words at its curved ends. So the corners are the row's,
        // with the focus ring following them inside the edge, as the
        // sign-in methods screen's wrapping buttons have it (#764).
        final shape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BgeTokens.of(context).radiusMd),
        );
        return TextButton(
          key: buttonKey,
          focusNode: focusNode,
          onPressed: onPressed,
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(shape),
            backgroundBuilder: BgeButtonFocusRing.builder(
              shape,
              placement: BgeButtonFocusRingPlacement.inside,
            ),
          ),
          child: Text(label),
        );
      },
    ),
  );
}

/// Delete: destructive, in the error colour. While the delete is out it
/// stays enabled and ignores presses, so it keeps focus, and its name says
/// it is deleting (STYLE_GUIDE §5).
class _DeleteButton extends StatelessWidget {
  const _DeleteButton({
    required this.deleting,
    required this.onPressed,
    required this.onFocusNode,
  });

  final bool deleting;

  /// Asks, then deletes. Null disables the button.
  final VoidCallback? onPressed;

  /// Given the button's focus node as it is built.
  final ValueChanged<FocusNode> onFocusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = ApiKeysLocalizations.of(context);
    final label = deleting ? l10n.apiKeyDeleting : l10n.apiKeyDelete;

    // Disabled while another write is out, the node `BgeOnlineOnly` merges
    // it into says so itself, as `BgeOnlineOnly` has it offline: Flutter's
    // text-contrast guideline reads a node's own flags, and would otherwise
    // hold the dimmed label to 4.5:1, which WCAG 1.4.3 exempts.
    return Semantics(
      enabled: onPressed == null ? false : null,
      child: BgeInertButton(
        inert: deleting,
        label: label,
        onPressed: onPressed,
        builder: (context, focusNode, onPressed) {
          onFocusNode(focusNode);
          return TextButton.icon(
            key: ApiKeyDetailScreen.deleteKey,
            focusNode: focusNode,
            onPressed: onPressed,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.delete_outline),
            // TextButton.icon puts the label in a Flexible, so it wraps.
            label: Text(label),
          );
        },
      ),
    );
  }
}
