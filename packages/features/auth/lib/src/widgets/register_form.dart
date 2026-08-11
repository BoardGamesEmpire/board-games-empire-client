import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:reactive_forms/reactive_forms.dart';

import '../../l10n/auth_localizations.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_bloc_state.dart';

/// Registration form for email/password sign-up.
///
/// Only rendered when the server's [EmailAndPasswordStrategy.signUpDisabled]
/// is false. Submits [AuthRegisterRequested] to the ancestor [AuthBloc].
///
/// i18n (#37): all copy — labels, hints, validation messages, button and
/// loading semantics — comes from [AuthLocalizations].
class RegisterForm extends StatefulWidget {
  const RegisterForm({super.key, this.onSwitchToSignIn});

  final VoidCallback? onSwitchToSignIn;

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  static const _kMinPasswordLength = 8;
  static const _kMinUsernameLength = 3;

  late final FormGroup _form;

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
          Validators.minLength(_kMinPasswordLength),
        ],
      ),
      'firstName': FormControl<String>(value: ''),
      'lastName': FormControl<String>(value: ''),
    });
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  void _submit(BuildContext context) {
    if (_form.invalid) {
      _form.markAllAsTouched();
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
        final isLoading = state is AuthLoading;

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
                  textInputAction: TextInputAction.next,
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
                  textInputAction: TextInputAction.next,
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
                        textInputAction: TextInputAction.next,
                        readOnly: isLoading,
                        validationMessages: const {},
                      ),
                    ),
                    const BgeGap.sm(axis: Axis.horizontal),
                    Expanded(
                      child: BgeTextField(
                        formControlName: 'lastName',
                        label: l10n.authLastNameLabel,
                        autofillHints: const [AutofillHints.familyName],
                        textInputAction: TextInputAction.next,
                        readOnly: isLoading,
                        validationMessages: const {},
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
                BgeSubmitButton(
                  label: l10n.authRegisterButton,
                  progressLabel: l10n.authRegisterLoadingLabel,
                  submitting: isLoading,
                  onPressed: () => _submit(context),
                ),
                if (widget.onSwitchToSignIn != null) ...[
                  const BgeGap.md(),
                  TextButton(
                    onPressed: isLoading ? null : widget.onSwitchToSignIn,
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
