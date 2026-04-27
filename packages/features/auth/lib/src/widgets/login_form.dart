import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:reactive_forms/reactive_forms.dart';

import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_bloc_state.dart';
import 'auth_text_field.dart';

/// Email and password sign-in form.
///
/// Submits [AuthSignInRequested] to the ancestor [AuthBloc].
/// Disables all inputs and shows a loading indicator while [AuthLoading]
/// is active. Keyboard users can submit with Enter on the password field.
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
    final theme = Theme.of(context);

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
                AuthTextField(
                  formControlName: 'email',
                  label: 'Email', // TODO: wire AuthLocalizations
                  hint: 'Enter your email address',
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  enabled: !isLoading,
                  autofocus: true,
                  validationMessages: {
                    ValidationMessage.required: (_) => 'Email is required',
                    ValidationMessage.email: (_) =>
                        'Enter a valid email address',
                  },
                ),
                const SizedBox(height: 16),
                AuthTextField(
                  formControlName: 'password',
                  label: 'Password',
                  hint: 'Enter your password',
                  isPassword: true,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  enabled: !isLoading,
                  onSubmitted: () => _submit(context),
                  validationMessages: {
                    ValidationMessage.required: (_) => 'Password is required',
                    ValidationMessage.minLength: (e) {
                      final min = (e as Map)['requiredLength'] as int;
                      return 'Password must be at least $min characters';
                    },
                  },
                ),
                const SizedBox(height: 24),
                Semantics(
                  button: true,
                  enabled: !isLoading,
                  label: isLoading ? 'Signing in, please wait' : 'Sign In',
                  child: FilledButton(
                    onPressed: isLoading ? null : () => _submit(context),
                    child: isLoading
                        ? SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.onPrimary,
                            ),
                          )
                        : const Text('Sign In'),
                  ),
                ),
                if (widget.onSwitchToRegister != null) ...[
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: isLoading ? null : widget.onSwitchToRegister,
                    child: const Text("Don't have an account? Register"),
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
