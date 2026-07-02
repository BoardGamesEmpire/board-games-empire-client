import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';

/// Accessible [FormBuilderTextField] wrapper for auth forms.
///
/// Accessibility features:
/// - `Semantics.label` ensures VoiceOver/TalkBack reads the field name
/// - A visually-hidden `liveRegion: true` [Semantics] node announces validation
///   errors immediately when they appear, without requiring the user to
///   re-navigate to the field.
///   flutter_form_builder has no reactive error stream (unlike reactive_forms'
///   `FormControl.errors`), so the error text is re-read from
///   [FormBuilderFieldState.errorText] in a post-frame callback scheduled on
///   every rebuild of this widget. Both keystrokes (via [onChanged] calling
///   `setState`) and a parent form's submit-time `validate()` call (which
///   rebuilds this widget as part of the ancestor rebuild) trigger that
///   rebuild, so the value read is never stale. The one gap versus the prior
///   implementation: a field blurred without any edit (pure tab-away) won't
///   push a new announcement, since nothing here triggers a rebuild in that
///   case — only the decoration's visible error text updates. Acceptable
///   trade-off; revisit if screen-reader QA flags it.
/// - Password visibility toggle meets the 48x48 minimum touch target
/// - `autofillHints` enables credential manager integration
/// - Keyboard users submit with Enter when [textInputAction] is [TextInputAction.done]
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    super.key,
    required this.name,
    required this.label,
    this.hint,
    this.autofillHints,
    this.textInputAction = TextInputAction.next,
    this.keyboardType,
    this.isPassword = false,
    this.onSubmitted,
    this.enabled = true,
    this.autofocus = false,
    this.validator,
  });

  /// The [FormBuilder] field name this control binds to.
  final String name;
  final String label;
  final String? hint;
  final Iterable<String>? autofillHints;
  final TextInputAction textInputAction;
  final TextInputType? keyboardType;
  final bool isPassword;
  final VoidCallback? onSubmitted;
  final bool enabled;
  final bool autofocus;

  /// Composed validator, e.g. via `FormBuilderValidators.compose([...])`.
  /// Kept as a plain [FormFieldValidator] so this widget stays decoupled
  /// from any specific validation package.
  final FormFieldValidator<String>? validator;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  bool _obscure = true;
  final _fieldKey =
      GlobalKey<FormBuilderFieldState<FormBuilderField<String>, String>>();
  final _liveError = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _liveError.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-sync the live-region announcer after this frame settles, so it
    // reflects whatever the field's own validator just produced.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final error = _fieldKey.currentState?.errorText;
      if (error != _liveError.value) {
        _liveError.value = error;
      }
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: widget.label,
          textField: true,
          child: FormBuilderTextField(
            key: _fieldKey,
            name: widget.name,
            autofocus: widget.autofocus,
            obscureText: widget.isPassword && _obscure,
            textInputAction: widget.textInputAction,
            keyboardType: widget.keyboardType,
            autofillHints: widget.autofillHints,
            enabled: widget.enabled,
            validator: widget.validator,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            onSubmitted: widget.onSubmitted != null
                ? (_) => widget.onSubmitted!()
                : null,
            // Forces a rebuild per keystroke so the postFrameCallback above
            // re-checks errorText; flutter_form_builder validates internally
            // regardless, this only drives our external live-region copy.
            onChanged: (_) => setState(() {}),
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
        ValueListenableBuilder<String?>(
          valueListenable: _liveError,
          builder: (context, message, _) {
            if (message == null || message.isEmpty) {
              return const SizedBox.shrink();
            }
            return Semantics(
              liveRegion: true,
              child: SizedBox(
                height: 0,
                child: OverflowBox(
                  maxHeight: double.infinity,
                  child: Text(message, style: const TextStyle(fontSize: 0)),
                ),
              ),
            );
          },
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
