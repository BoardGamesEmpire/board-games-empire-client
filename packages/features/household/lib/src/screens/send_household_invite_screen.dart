import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/send_household_invite_bloc.dart';
import '../bloc/send_household_invite_event.dart';
import '../bloc/send_household_invite_state.dart';
import '../bloc/user_search_bloc.dart';
import '../bloc/user_search_event.dart';
import '../bloc/user_search_state.dart';
import '../invites/household_invite_permissions.dart';
import '../invites/invite_refusal_message.dart';
import '../widgets/household_role_label.dart';

/// The form for inviting someone to a household (#455): by email address,
/// or by picking someone who has an account through user search.
///
/// The roles offered depend on [viewerRole], through
/// [HouseholdInvitePermissions.offerableRoles]. A viewer who may offer none
/// sees a short explanation instead of the form, which only a deep link can
/// reach: the list offers no invite button to them.
///
/// Decoupled from DI like the other household screens: the caller resolves
/// [viewerRole] and the per-server [HouseholdInviteRemoteDataSource], and
/// leaves the screen in [onSent].
class SendHouseholdInviteScreen extends StatelessWidget {
  const SendHouseholdInviteScreen({
    required this.householdId,
    required this.viewerRole,
    required this.remote,
    required this.onSent,
    super.key,
  });

  static const Key modeKey = Key('send_household_invite.mode');
  static const Key emailKey = Key('send_household_invite.email');
  static const Key searchKey = Key('send_household_invite.search');
  static const Key nameKey = Key('send_household_invite.name');
  static const Key roleKey = Key('send_household_invite.role');
  static const Key messageKey = Key('send_household_invite.message');
  static const Key submitKey = Key('send_household_invite.submit');
  static const Key errorKey = Key('send_household_invite.error');

  /// Per-result key: `send_household_invite.result_<userId>`.
  static Key resultKey(String userId) =>
      Key('send_household_invite.result_$userId');

  final String householdId;

  /// The viewer's role in the household, or null when the cache could not
  /// say.
  final HouseholdRole? viewerRole;
  final HouseholdInviteRemoteDataSource remote;

  /// Called once the invite is sent, with this screen's context. A
  /// confirmation SnackBar is already showing, above the route.
  final void Function(BuildContext context) onSent;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final roles = HouseholdInvitePermissions.offerableRoles(viewerRole);

    if (roles.isEmpty) {
      return BgePage(
        title: Text(l10n.inviteSendTitle),
        width: BgePageWidth.pane,
        centerVertically: true,
        child: Text(
          l10n.inviteSendNotAllowed,
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      );
    }

    return MultiBlocProvider(
      // A new household is a new form (#466).
      key: ValueKey<String>(householdId),
      providers: [
        BlocProvider(
          create: (_) =>
              SendHouseholdInviteBloc(householdId: householdId, remote: remote),
        ),
        BlocProvider(create: (_) => UserSearchBloc(remote: remote)),
      ],
      child: BlocListener<SendHouseholdInviteBloc, SendHouseholdInviteState>(
        listenWhen: (_, state) => state is SendHouseholdInviteSent,
        listener: (context, _) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l10n.inviteSendDone)));
          onSent(context);
        },
        child: BgePage(
          title: Text(l10n.inviteSendTitle),
          width: BgePageWidth.pane,
          child: _SendForm(roles: roles),
        ),
      ),
    );
  }
}

enum _Mode { email, person }

class _SendForm extends StatefulWidget {
  const _SendForm({required this.roles});

  /// What the viewer may offer, in picker order. Never empty.
  final List<HouseholdRole> roles;

  @override
  State<_SendForm> createState() => _SendFormState();
}

class _SendFormState extends State<_SendForm> {
  late final FormGroup _form = FormGroup({
    'email': FormControl<String>(validators: [Validators.delegate(_email)]),
    // Not a field: the person picked from the search. Disabled in email
    // mode, where it is not asked for, so it never blocks that submit.
    'picked': FormControl<String>(
      validators: [Validators.required],
      disabled: true,
    ),
    'search': FormControl<String>(),
    'name': FormControl<String>(
      validators: [
        Validators.delegate(
          (c) => _maxTrimmed(c, HouseholdInviteDraft.maxNameLength),
        ),
      ],
    ),
    'role': FormControl<HouseholdRole>(value: _defaultRole(widget.roles)),
    'message': FormControl<String>(
      validators: [
        Validators.delegate(
          (c) => _maxTrimmed(c, HouseholdInviteDraft.maxMessageLength),
        ),
      ],
    ),
  });

  _Mode _mode = _Mode.email;
  UserSummary? _picked;
  StreamSubscription<Object?>? _searchSubscription;
  StreamSubscription<Object?>? _editSubscription;

  /// Required, and an address once trimmed: the draft trims it, so a value
  /// with spaces around it is valid here.
  static Map<String, dynamic>? _email(AbstractControl<dynamic> control) {
    final value = control.value;
    final trimmed = value is String ? value.trim() : '';
    if (trimmed.isEmpty) return {ValidationMessage.required: true};
    return EmailValidator.emailRegex.hasMatch(trimmed)
        ? null
        : {ValidationMessage.email: true};
  }

  /// The draft's length limits, counted after trimming as the draft does.
  static Map<String, dynamic>? _maxTrimmed(
    AbstractControl<dynamic> control,
    int max,
  ) {
    final value = control.value;
    final trimmed = value is String ? value.trim() : '';
    return trimmed.length > max ? {ValidationMessage.maxLength: true} : null;
  }

  /// Member where it may be offered, which is everywhere today.
  static HouseholdRole _defaultRole(List<HouseholdRole> roles) =>
      roles.contains(HouseholdRole.householdMember)
      ? HouseholdRole.householdMember
      : roles.first;

  @override
  void didUpdateWidget(_SendForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The viewer's role changed under the form. A role no longer theirs to
    // offer is not left picked, where the picker would have no item for it.
    final role = _form.control('role');
    if (!widget.roles.contains(role.value)) {
      role.value = _defaultRole(widget.roles);
    }
  }

  @override
  void initState() {
    super.initState();
    _searchSubscription = _form.control('search').valueChanges.listen((query) {
      if (!mounted) return;
      // A new search drops the last pick: it may not be among the results.
      if (_picked != null) _pick(null);
      context.read<UserSearchBloc>().add(
        UserSearchQueryChanged(query as String? ?? ''),
      );
    });
    // A failure describes the values it was sent with, so any change,
    // including a mode switch, retires it. The bloc drops the event unless a
    // failure is showing.
    _editSubscription = _form.valueChanges.listen((_) {
      if (mounted) {
        context.read<SendHouseholdInviteBloc>().add(
          const SendHouseholdInviteEdited(),
        );
      }
    });
  }

  @override
  void dispose() {
    unawaited(_searchSubscription?.cancel());
    unawaited(_editSubscription?.cancel());
    _form.dispose();
    super.dispose();
  }

  void _setMode(_Mode mode) {
    setState(() => _mode = mode);
    final email = _form.control('email');
    final picked = _form.control('picked');
    if (mode == _Mode.email) {
      email.markAsEnabled();
      picked.markAsDisabled();
    } else {
      email.markAsDisabled();
      picked.markAsEnabled();
    }
  }

  void _pick(UserSummary? user) {
    setState(() => _picked = user);
    _form.control('picked').value = user?.id;
  }

  void _submit(bool submitting) {
    if (submitting) return;
    if (!_form.valid) {
      _form.rejectSubmit();
      setState(() {});
      return;
    }
    final draft = HouseholdInviteDraft(
      invitee: switch (_mode) {
        _Mode.email => InviteeEmail(_form.control('email').value as String),
        _Mode.person => InviteeUser(_picked!.id),
      },
      inviteeName: _form.control('name').value as String?,
      role: _form.control('role').value as HouseholdRole,
      message: _form.control('message').value as String?,
    );
    context.read<SendHouseholdInviteBloc>().add(
      SendHouseholdInviteSubmitted(draft),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);

    return BlocBuilder<SendHouseholdInviteBloc, SendHouseholdInviteState>(
      builder: (context, state) {
        // Sent counts too: the form is about to close.
        final submitting =
            state is SendHouseholdInviteSending ||
            state is SendHouseholdInviteSent;
        final pickedControl = _form.control('picked');

        return ReactiveForm(
          formGroup: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<_Mode>(
                key: SendHouseholdInviteScreen.modeKey,
                segments: [
                  ButtonSegment(
                    value: _Mode.email,
                    label: Text(l10n.inviteSendByEmail),
                    icon: const Icon(Icons.alternate_email),
                  ),
                  ButtonSegment(
                    value: _Mode.person,
                    label: Text(l10n.inviteSendByPerson),
                    icon: const Icon(Icons.person_search_outlined),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: submitting
                    ? null
                    : (selected) => _setMode(selected.single),
              ),
              const BgeGap.lg(),
              if (_mode == _Mode.email)
                BgeTextField(
                  key: SendHouseholdInviteScreen.emailKey,
                  formControlName: 'email',
                  label: l10n.inviteSendEmailLabel,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  enableSuggestions: false,
                  readOnly: submitting,
                  validationMessages: {
                    ValidationMessage.required: (_) =>
                        l10n.inviteSendEmailRequired,
                    ValidationMessage.email: (_) => l10n.inviteSendEmailInvalid,
                  },
                )
              else ...[
                BgeTextField(
                  key: SendHouseholdInviteScreen.searchKey,
                  formControlName: 'search',
                  label: l10n.inviteSendSearchLabel,
                  helper: l10n.inviteSendSearchHint,
                  autocorrect: false,
                  readOnly: submitting,
                ),
                const BgeGap.sm(),
                _SearchResults(
                  picked: _picked,
                  onPick: submitting ? null : _pick,
                ),
                // Not a field, so it has no field's error line: announced
                // the way BgeTextField announces one.
                if (pickedControl.invalid && pickedControl.touched)
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.inviteSendPickRequired,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
              const BgeGap.md(),
              BgeTextField(
                key: SendHouseholdInviteScreen.nameKey,
                formControlName: 'name',
                label: l10n.inviteSendNameLabel,
                readOnly: submitting,
                validationMessages: {
                  ValidationMessage.maxLength: (_) =>
                      l10n.inviteSendNameTooLong,
                },
              ),
              const BgeGap.md(),
              ReactiveDropdownField<HouseholdRole>(
                key: SendHouseholdInviteScreen.roleKey,
                formControlName: 'role',
                readOnly: submitting,
                decoration: InputDecoration(
                  labelText: l10n.inviteSendRoleLabel,
                ),
                items: [
                  for (final role in widget.roles)
                    DropdownMenuItem(
                      value: role,
                      child: Text(householdRoleLabel(l10n, role)),
                    ),
                ],
              ),
              const BgeGap.md(),
              BgeTextField(
                key: SendHouseholdInviteScreen.messageKey,
                formControlName: 'message',
                label: l10n.inviteSendMessageLabel,
                readOnly: submitting,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                minLines: 2,
                maxLines: 5,
                validationMessages: {
                  ValidationMessage.maxLength: (_) =>
                      l10n.inviteSendMessageTooLong,
                },
              ),
              const BgeGap.lg(),
              BgeFormActions(
                failure: state is SendHouseholdInviteFailed
                    ? BgeFormFailure(
                        key: SendHouseholdInviteScreen.errorKey,
                        title: l10n.inviteSendFailedTitle,
                        message: inviteRefusalMessage(
                          l10n,
                          HouseholdInviteAction.send,
                          state.error,
                        ),
                      )
                    : null,
                action: BgeSubmitButton(
                  key: SendHouseholdInviteScreen.submitKey,
                  label: l10n.inviteSendSubmit,
                  progressLabel: l10n.inviteSendSending,
                  submitting: submitting,
                  onPressed: () => _submit(submitting),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What the search found, as rows to pick one from.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.picked, required this.onPick});

  final UserSummary? picked;

  /// Null while sending: the pick is fixed.
  final void Function(UserSummary user)? onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);

    return BlocBuilder<UserSearchBloc, UserSearchState>(
      builder: (context, state) => switch (state) {
        UserSearchIdle() => const SizedBox.shrink(),
        UserSearchLoading() => const LinearProgressIndicator(),
        UserSearchFailed() => Text(
          l10n.inviteSendSearchFailed,
          style: theme.textTheme.bodyMedium,
        ),
        UserSearchResults(:final users) when users.isEmpty => Text(
          l10n.inviteSendSearchEmpty,
          style: theme.textTheme.bodyMedium,
        ),
        UserSearchResults(:final users) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final user in users)
              ListTile(
                key: SendHouseholdInviteScreen.resultKey(user.id),
                title: Text(user.label),
                subtitle: user.displayName == null ? null : Text(user.username),
                selected: picked?.id == user.id,
                trailing: picked?.id == user.id
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: onPick == null ? null : () => onPick!(user),
              ),
          ],
        ),
      },
    );
  }
}
