import 'dart:async';

import 'package:auth/l10n/auth_localizations.dart';
import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/password_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Registration form for email/password sign-up.
///
/// Only rendered when the server's [EmailAndPasswordStrategy.signUpDisabled]
/// is false. Submits [AuthRegisterRequested] to the ancestor [AuthBloc].
/// While its own registration is in flight ([AuthLoading] with no provider)
/// the fields go read-only and the submit shows its progress. While a
/// provider sign-in is open, the fields stay as they are and the submit is
/// disabled, with no progress shown (#583).
///
/// i18n (#37): all copy — labels, hints, validation messages, button and
/// loading semantics — comes from [AuthLocalizations].
class RegisterForm extends StatefulWidget {
  const RegisterForm({super.key, this.failure, this.onSwitchToSignIn});

  /// The failure of the last registration, shown above the submit. The
  /// screen supplies it, with its copy and title.
  final BgeFormFailure? failure;

  final VoidCallback? onSwitchToSignIn;

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  static const _kMinUsernameLength = 3;

  late final FormGroup _form;
  StreamSubscription<Object?>? _editSubscription;

  @override
  void initState() {
    super.initState();
    _form = FormGroup({
      'email': FormControl<String>(
        value: '',
        validators: [Validators.required, Validators.email],
      ),
      'username': FormControl<String>(
        value: '',
        validators: [
          Validators.required,
          Validators.minLength(_kMinUsernameLength),
        ],
      ),
      'password': FormControl<String>(
        value: '',
        validators: [
          Validators.required,
          Validators.minLength(kMinRegistrationPasswordLength),
        ],
      ),
      'firstName': FormControl<String>(value: ''),
      'lastName': FormControl<String>(value: ''),
    });
    _editSubscription = _form.valueChanges.listen(_retireFailureOnEdit);
  }

  @override
  void dispose() {
    _editSubscription?.cancel();
    _form.dispose();
    super.dispose();
  }

  /// Retires a spent failure banner as soon as the user edits.
  ///
  /// The banner is bound to bloc state and does not fade the way the SnackBar
  /// it replaced did, so without this the user reads a complaint about the
  /// credentials they are in the middle of correcting (#191). Dispatched
  /// straight to the bloc rather than handed up as a callback because this
  /// form already talks to the bloc — its submit does the same.
  ///
  /// The bloc drops the event unless a failure is actually showing, so the
  /// per-keystroke event is a no-op in the common case.
  void _retireFailureOnEdit(Object? _) {
    if (!mounted) return;
    final bloc = context.read<AuthBloc>();
    if (bloc.state is AuthOperationFailure) {
      bloc.add(const AuthFailureCleared());
    }
  }

  void _submit(BuildContext context) {
    // Nothing starts while a sign-in runs. While a provider's is open the
    // fields are editable, so their done action reaches here even though the
    // submit is disabled (#583).
    if (context.read<AuthBloc>().state is AuthLoading) return;
    if (_form.invalid) {
      _form.rejectSubmit();
      return;
    }

    final firstName = (_form.control('firstName').value as String).trim();
    final lastName = (_form.control('lastName').value as String).trim();

    context.read<AuthBloc>().add(
      AuthRegisterRequested(
        email: _form.control('email').value as String,
        password: _form.control('password').value as String,
        username: _form.control('username').value as String,
        firstName: firstName.isEmpty ? null : firstName,
        lastName: lastName.isEmpty ? null : lastName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AuthLocalizations.of(context);

    return BlocBuilder<AuthBloc, AuthBlocState>(
      builder: (context, state) {
        // A provider sign-in is open in the browser (#583). This form's
        // submission isn't what is running, so it shows no progress and its
        // fields stay as they are at rest. Its submit is unavailable for a
        // press that isn't its own, so it has no focus to keep, and is
        // disabled (STYLE_GUIDE §5).
        final providerOpen = state is AuthLoading && state.isProviderSignIn;
        // This form's own submission is in flight.
        final isLoading = state is AuthLoading && !providerOpen;

        return ReactiveForm(
          formGroup: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                BgeTextField(
                  formControlName: 'email',
                  label: l10n.authEmailLabel,
                  hint: l10n.authEmailHint,
                  keyboardType: TextInputType.emailAddress,
                  // An address is not prose. The old AuthTextField exposed no
                  // way to say so, so these were autocorrected.
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.email],
                  readOnly: isLoading,
                  autofocus: true,
                  validationMessages: {
                    ValidationMessage.required: (_) => l10n.authErrorRequired,
                    ValidationMessage.email: (_) => l10n.authErrorInvalidEmail,
                  },
                ),
                const BgeGap.md(),
                BgeTextField(
                  formControlName: 'username',
                  label: l10n.authUsernameLabel,
                  hint: l10n.authUsernameHint,
                  // An identifier, not prose — same rule as the email field.
                  // Autocorrect on a credential silently alters what the user
                  // believes they typed.
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.username],
                  readOnly: isLoading,
                  validationMessages: {
                    ValidationMessage.required: (_) => l10n.authErrorRequired,
                    ValidationMessage.minLength: (e) =>
                        l10n.authErrorUsernameTooShort(
                          (e as Map)['requiredLength'] as int,
                        ),
                  },
                ),
                const BgeGap.md(),
                // Optional name fields — side by side on wider screens
                Row(
                  children: [
                    Expanded(
                      child: BgeTextField(
                        formControlName: 'firstName',
                        label: l10n.authFirstNameLabel,
                        autofillHints: const [AutofillHints.givenName],
                        readOnly: isLoading,
                      ),
                    ),
                    const BgeGap.sm(axis: Axis.horizontal),
                    Expanded(
                      child: BgeTextField(
                        formControlName: 'lastName',
                        label: l10n.authLastNameLabel,
                        autofillHints: const [AutofillHints.familyName],
                        readOnly: isLoading,
                      ),
                    ),
                  ],
                ),
                const BgeGap.md(),
                BgeTextField(
                  formControlName: 'password',
                  label: l10n.authPasswordLabel,
                  hint: l10n.authPasswordCreateHint,
                  isPassword: true,
                  revealLabel: l10n.authPasswordShow,
                  obscureLabel: l10n.authPasswordHide,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.done,
                  readOnly: isLoading,
                  onSubmitted: () => _submit(context),
                  validationMessages: {
                    ValidationMessage.required: (_) => l10n.authErrorRequired,
                    ValidationMessage.minLength: (e) =>
                        l10n.authErrorPasswordTooShort(
                          (e as Map)['requiredLength'] as int,
                        ),
                  },
                ),
                const BgeGap.lg(),
                BgeFormActions(
                  failure: widget.failure,
                  action: BgeSubmitButton(
                    label: l10n.authRegisterButton,
                    progressLabel: l10n.authRegisterLoadingLabel,
                    submitting: isLoading,
                    onPressed: providerOpen ? null : () => _submit(context),
                  ),
                ),
                if (widget.onSwitchToSignIn != null) ...[
                  const BgeGap.md(),
                  TextButton(
                    // Off while any sign-in runs, a provider's included.
                    onPressed: state is AuthLoading
                        ? null
                        : widget.onSwitchToSignIn,
                    child: Text(l10n.authSwitchToSignIn),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
