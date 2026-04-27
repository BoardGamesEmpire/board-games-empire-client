import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:reactive_forms/reactive_forms.dart';

import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_bloc_state.dart';
import 'auth_text_field.dart';

/// Registration form for email/password sign-up.
///
/// Only rendered when the server's [EmailAndPasswordStrategy.signUpDisabled]
/// is false. Submits [AuthRegisterRequested] to the ancestor [AuthBloc].
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
                  label: 'Email',
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
                  formControlName: 'username',
                  label: 'Username',
                  hint: 'Choose a username',
                  autofillHints: const [AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  enabled: !isLoading,
                  validationMessages: {
                    ValidationMessage.required: (_) => 'Username is required',
                    ValidationMessage.minLength: (e) {
                      final min = (e as Map)['requiredLength'] as int;
                      return 'Username must be at least $min characters';
                    },
                  },
                ),
                const SizedBox(height: 16),
                // Optional name fields — side by side on wider screens
                Row(
                  children: [
                    Expanded(
                      child: AuthTextField(
                        formControlName: 'firstName',
                        label: 'First Name',
                        autofillHints: const [AutofillHints.givenName],
                        textInputAction: TextInputAction.next,
                        enabled: !isLoading,
                        validationMessages: const {},
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AuthTextField(
                        formControlName: 'lastName',
                        label: 'Last Name',
                        autofillHints: const [AutofillHints.familyName],
                        textInputAction: TextInputAction.next,
                        enabled: !isLoading,
                        validationMessages: const {},
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AuthTextField(
                  formControlName: 'password',
                  label: 'Password',
                  hint: 'Create a password',
                  isPassword: true,
                  autofillHints: const [AutofillHints.newPassword],
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
                  label: isLoading
                      ? 'Creating account, please wait'
                      : 'Create Account',
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
                        : const Text('Create Account'),
                  ),
                ),
                if (widget.onSwitchToSignIn != null) ...[
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: isLoading ? null : widget.onSwitchToSignIn,
                    child: const Text('Already have an account? Sign in'),
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
