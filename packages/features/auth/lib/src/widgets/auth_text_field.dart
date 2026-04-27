import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';

/// Accessible [ReactiveTextField] wrapper for auth forms.
///
/// Accessibility features:
/// - `Semantics.label` ensures VoiceOver/TalkBack reads the field name
/// - A visually-hidden `liveRegion: true` [Semantics] node announces validation
///   errors immediately when they appear, without requiring the user to
///   re-navigate to the field
/// - Password visibility toggle meets the 48×48 minimum touch target
/// - `autofillHints` enables credential manager integration
/// - Keyboard users submit with Enter when [textInputAction] is [TextInputAction.done]
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    super.key,
    required this.formControlName,
    required this.label,
    this.hint,
    this.autofillHints,
    this.textInputAction = TextInputAction.next,
    this.keyboardType,
    this.isPassword = false,
    this.onSubmitted,
    this.enabled = true,
    this.autofocus = false,
    this.validationMessages = const {},
  });

  final String formControlName;
  final String label;
  final String? hint;
  final Iterable<String>? autofillHints;
  final TextInputAction textInputAction;
  final TextInputType? keyboardType;
  final bool isPassword;
  final VoidCallback? onSubmitted;
  final bool enabled;
  final bool autofocus;

  /// Maps reactive_forms error keys to human-readable messages.
  /// e.g. `{ValidationMessage.required: (_) => 'Required'}`
  final Map<String, String Function(Object)> validationMessages;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: widget.label,
          textField: true,
          child: ReactiveTextField<String>(
            formControlName: widget.formControlName,
            autofocus: widget.autofocus,
            obscureText: widget.isPassword && _obscure,
            textInputAction: widget.textInputAction,
            keyboardType: widget.keyboardType,
            autofillHints: widget.autofillHints,
            onSubmitted: widget.onSubmitted != null
                ? (_) => widget.onSubmitted!()
                : null,
            validationMessages: widget.validationMessages,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              suffixIcon: widget.isPassword
                  ? _buildVisibilityToggle(context)
                  : null,
            ),
          ),
        ),
        // Live-region error node — screen readers announce this immediately
        // when it becomes non-empty, even without re-focusing the field.
        _LiveErrorAnnouncer(
          formControlName: widget.formControlName,
          validationMessages: widget.validationMessages,
        ),
      ],
    );
  }

  Widget _buildVisibilityToggle(BuildContext context) {
    final isObscured = _obscure;
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        icon: Icon(isObscured ? Icons.visibility : Icons.visibility_off),
        tooltip: isObscured ? 'Show password' : 'Hide password',
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    );
  }
}

/// Renders an invisible live-region node that announces validation errors.
///
/// Uses [ReactiveFormConsumer] scoped only to this control so rebuilds are
/// surgical. The text node has zero size but is visible to the accessibility
/// tree via [Semantics.liveRegion].
class _LiveErrorAnnouncer extends StatelessWidget {
  const _LiveErrorAnnouncer({
    required this.formControlName,
    required this.validationMessages,
  });

  final String formControlName;
  final Map<String, String Function(Object)> validationMessages;

  @override
  Widget build(BuildContext context) {
    return ReactiveFormConsumer(
      builder: (context, form, _) {
        final control = form.control(formControlName);
        if (!control.invalid || !control.touched) {
          return const SizedBox.shrink();
        }

        final errorKey = control.errors.keys.firstOrNull;
        if (errorKey == null) {
          return const SizedBox.shrink();
        }

        final message = validationMessages[errorKey]?.call(
          control.errors[errorKey]!,
        );

        if (message == null) {
          return const SizedBox.shrink();
        }

        return Semantics(
          liveRegion: true,
          // ExcludeSemantics: false so the live-region text IS in the tree
          child: SizedBox(
            height: 0,
            child: OverflowBox(
              maxHeight: double.infinity,
              child: Text(message, style: const TextStyle(fontSize: 0)),
            ),
          ),
        );
      },
    );
  }
}
