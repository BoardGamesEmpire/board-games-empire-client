import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';

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

  final _formKey = GlobalKey<FormBuilderState>();

  void _submit(BuildContext context) {
    final isValid = _formKey.currentState?.saveAndValidate() ?? false;
    if (!isValid) return;

    final values = _formKey.currentState!.value;
    context.read<AuthBloc>().add(
      AuthSignInRequested(
        email: values['email'] as String,
        password: values['password'] as String,
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
                  label: 'Email', // TODO: wire AuthLocalizations
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
                  name: 'password',
                  label: 'Password',
                  hint: 'Enter your password',
                  isPassword: true,
                  autofillHints: const [AutofillHints.password],
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
