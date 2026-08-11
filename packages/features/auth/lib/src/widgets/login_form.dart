import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:reactive_forms/reactive_forms.dart';

import '../../l10n/auth_localizations.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_bloc_state.dart';

/// Email and password sign-in form.
///
/// Submits [AuthSignInRequested] to the ancestor [AuthBloc].
/// Disables all inputs and shows a loading indicator while [AuthLoading]
/// is active. Keyboard users can submit with Enter on the password field.
///
/// i18n (#37): all copy — labels, hints, validation messages, button and
/// loading semantics — comes from [AuthLocalizations].
class LoginForm extends StatefulWidget {
  const LoginForm({super.key, this.onSwitchToRegister});

  /// Called when the user taps the "Create account" link.
  final VoidCallback? onSwitchToRegister;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  static const _kMinPasswordLength = 8;

  late final FormGroup _form;

  @override
  void initState() {
    super.initState();
    _form = FormGroup({
      'email': FormControl<String>(
        value: '',
        validators: [Validators.required, Validators.email],
      ),
      'password': FormControl<String>(
        value: '',
        validators: [
          Validators.required,
          Validators.minLength(_kMinPasswordLength),
        ],
      ),
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
    context.read<AuthBloc>().add(
      AuthSignInRequested(
        email: _form.control('email').value as String,
        password: _form.control('password').value as String,
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
                  formControlName: 'password',
                  label: l10n.authPasswordLabel,
                  hint: l10n.authPasswordHint,
                  isPassword: true,
                  revealLabel: l10n.authPasswordShow,
                  obscureLabel: l10n.authPasswordHide,
                  autofillHints: const [AutofillHints.password],
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
                  label: l10n.authSignInButton,
                  progressLabel: l10n.authLoadingLabel,
                  submitting: isLoading,
                  onPressed: () => _submit(context),
                ),
                if (widget.onSwitchToRegister != null) ...[
                  const BgeGap.md(),
                  TextButton(
                    onPressed: isLoading ? null : widget.onSwitchToRegister,
                    child: Text(l10n.authSwitchToRegister),
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
