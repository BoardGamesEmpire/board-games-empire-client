import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';

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

  final _formKey = GlobalKey<FormBuilderState>();

  void _submit(BuildContext context) {
    final isValid = _formKey.currentState?.saveAndValidate() ?? false;
    if (!isValid) return;

    final values = _formKey.currentState!.value;
    final firstName = (values['firstName'] as String? ?? '').trim();
    final lastName = (values['lastName'] as String? ?? '').trim();

    context.read<AuthBloc>().add(
      AuthRegisterRequested(
        email: values['email'] as String,
        password: values['password'] as String,
        username: values['username'] as String,
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

        return FormBuilder(
          key: _formKey,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AuthTextField(
                  name: 'email',
                  label: 'Email',
                  hint: 'Enter your email address',
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  enabled: !isLoading,
                  autofocus: true,
                  validator: FormBuilderValidators.compose([
                    FormBuilderValidators.required(
                      errorText: 'Email is required',
                    ),
                    FormBuilderValidators.email(
                      errorText: 'Enter a valid email address',
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                AuthTextField(
                  name: 'username',
                  label: 'Username',
                  hint: 'Choose a username',
                  autofillHints: const [AutofillHints.username],
                  textInputAction: TextInputAction.next,
                  enabled: !isLoading,
                  validator: FormBuilderValidators.compose([
                    FormBuilderValidators.required(
                      errorText: 'Username is required',
                    ),
                    FormBuilderValidators.minLength(
                      _kMinUsernameLength,
                      errorText:
                          'Username must be at least '
                          '$_kMinUsernameLength characters',
                    ),
                  ]),
                ),
                const SizedBox(height: 16),
                // Optional name fields — side by side on wider screens
                Row(
                  children: [
                    Expanded(
                      child: AuthTextField(
                        name: 'firstName',
                        label: 'First Name',
                        autofillHints: const [AutofillHints.givenName],
                        textInputAction: TextInputAction.next,
                        enabled: !isLoading,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AuthTextField(
                        name: 'lastName',
                        label: 'Last Name',
                        autofillHints: const [AutofillHints.familyName],
                        textInputAction: TextInputAction.next,
                        enabled: !isLoading,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AuthTextField(
                  name: 'password',
                  label: 'Password',
                  hint: 'Create a password',
                  isPassword: true,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.done,
                  enabled: !isLoading,
                  onSubmitted: () => _submit(context),
                  validator: FormBuilderValidators.compose([
                    FormBuilderValidators.required(
                      errorText: 'Password is required',
                    ),
                    FormBuilderValidators.minLength(
                      _kMinPasswordLength,
                      errorText:
                          'Password must be at least '
                          '$_kMinPasswordLength characters',
                    ),
                  ]),
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
