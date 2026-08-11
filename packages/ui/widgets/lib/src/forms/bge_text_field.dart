import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The standard form field: an accessible [ReactiveTextField] wrapper (#165).
///
/// Promoted out of `features/auth`, where it was the best of the three text
/// fields in the codebase — the other two were hand-rolled per feature and had
/// drifted, one of them passing its own `OutlineInputBorder` so household's
/// fields visibly differed from server-onboarding's. That border now comes from
/// the theme, so every field in the app matches by default.
///
/// ## Accessibility
///
/// - A visible label, always — never hint-only. A hint disappears the moment
///   the user types, taking with it the only clue about what the field wanted.
/// - [Semantics.label] so VoiceOver/TalkBack read the field name.
/// - A visually-hidden **live region** announces validation errors the moment
///   they appear. Without it, a screen-reader user learns a field is invalid
///   only by navigating back onto it — which is how a form ends up feeling
///   broken rather than merely strict.
/// - The password visibility toggle meets the 48×48 minimum touch target
///   (`BgeTokens.minTapTarget`, WCAG 2.5.5).
/// - [autofillHints] enables credential-manager integration.
class BgeTextField extends StatefulWidget {
  /// Creates a form field bound to [formControlName] in the enclosing
  /// `ReactiveForm`.
  const BgeTextField({
    required this.formControlName,
    required this.label,
    this.hint,
    this.helper,
    this.autofillHints,
    this.textInputAction = TextInputAction.next,
    this.keyboardType,
    this.isPassword = false,
    this.obscureLabel,
    this.revealLabel,
    this.onSubmitted,
    this.readOnly = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.validationMessages = const {},
    super.key,
  });

  /// The control this field binds to.
  final String formControlName;

  /// Visible label. Also the field's accessible name.
  final String label;

  /// Optional placeholder shown while empty.
  final String? hint;

  /// Optional persistent helper text below the field.
  final String? helper;

  /// Autofill hints, e.g. `[AutofillHints.email]`.
  final Iterable<String>? autofillHints;

  /// Keyboard action. [TextInputAction.done] pairs with [onSubmitted].
  final TextInputAction textInputAction;

  /// Keyboard type.
  final TextInputType? keyboardType;

  /// Whether this is a password field, which adds a visibility toggle.
  final bool isPassword;

  /// Localized tooltip/semantic label for "hide password". Required in
  /// practice when [isPassword] is set — see [revealLabel].
  final String? obscureLabel;

  /// Localized tooltip/semantic label for "show password".
  ///
  /// Null falls back to an English default. That fallback exists so this
  /// package stays free of localization delegates (its stated convention), not
  /// because English is acceptable in shipped UI — pass the localized strings.
  final String? revealLabel;

  /// Invoked on the keyboard's submit action.
  final VoidCallback? onSubmitted;

  /// Whether the field rejects edits — the in-flight state, where the value
  /// was already captured at submit and further edits would be silently
  /// discarded.
  ///
  /// **This is deliberately `readOnly` rather than `enabled: false`, app-wide.**
  /// A disabled field is removed from focus traversal, so a screen-reader or
  /// keyboard user mid-form has the control vanish underneath them for the
  /// duration of a network call. Read-only keeps it present and readable —
  /// the user can still review what they submitted — and still tears down the
  /// input connection, which closes the keyboard submit path. The in-flight
  /// signal is carried by [BgeSubmitButton]'s label and spinner instead.
  ///
  /// This widget intentionally exposes no `enabled`: offering both would let
  /// two screens make opposite choices about the same moment, which is the
  /// class of drift this package exists to stop.
  final bool readOnly;

  /// Whether the platform may autocorrect typed text. Defaults to true.
  ///
  /// **Set false for anything that is not prose** — URLs, hostnames, IDs,
  /// codes. A keyboard that "corrects" a self-hosted server address produces
  /// a failure the user cannot see the cause of, because the field still shows
  /// what they believe they typed.
  final bool autocorrect;

  /// Whether the platform may offer completions. Usually tracks [autocorrect]
  /// — both are the keyboard trying to be helpful about natural language.
  final bool enableSuggestions;

  /// Whether to focus this field on first build.
  final bool autofocus;

  /// Minimum visible lines.
  final int? minLines;

  /// Maximum visible lines.
  final int? maxLines;

  /// Maps reactive_forms error keys to localized messages.
  final Map<String, String Function(Object)> validationMessages;

  @override
  State<BgeTextField> createState() => _BgeTextFieldState();
}

class _BgeTextFieldState extends State<BgeTextField> {
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
            readOnly: widget.readOnly,
            autocorrect: widget.autocorrect,
            enableSuggestions: widget.enableSuggestions,
            obscureText: widget.isPassword && _obscure,
            textInputAction: widget.textInputAction,
            keyboardType: widget.keyboardType,
            autofillHints: widget.autofillHints,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            onSubmitted: widget.onSubmitted != null
                ? (_) => widget.onSubmitted!()
                : null,
            validationMessages: widget.validationMessages,
            decoration: InputDecoration(
              // Label, not hint-only. The border comes from the theme.
              labelText: widget.label,
              hintText: widget.hint,
              helperText: widget.helper,
              suffixIcon: widget.isPassword ? _visibilityToggle(context) : null,
            ),
          ),
        ),
        _LiveErrorAnnouncer(
          formControlName: widget.formControlName,
          validationMessages: widget.validationMessages,
        ),
      ],
    );
  }

  Widget _visibilityToggle(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final label = _obscure
        ? (widget.revealLabel ?? 'Show password')
        : (widget.obscureLabel ?? 'Hide password');

    return SizedBox(
      // Explicit rather than relying on IconButton's default: the field's
      // suffix slot constrains its child, and a toggle that shrinks below
      // 48dp is a WCAG 2.5.5 failure on the control users hit most often.
      width: tokens.minTapTarget,
      height: tokens.minTapTarget,
      child: IconButton(
        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
        tooltip: label,
        onPressed: () => setState(() => _obscure = !_obscure),
      ),
    );
  }
}

/// A zero-size node that announces validation errors as they appear.
///
/// The announcement rides a [Semantics.label] on a 1×1 box rather than
/// rendering invisible text. The earlier version of this widget drew a real
/// `Text` at `fontSize: 0` inside an `OverflowBox` — which put a raw font size
/// in the widget tree purely to hide something, and is the kind of trick that
/// gets "cleaned up" by someone who does not realize it is load-bearing.
///
/// ## Why it subscribes to two streams
///
/// The obvious implementation — wrapping this in `ReactiveFormConsumer` — is
/// what the auth-feature original did, and it **never fired**.
/// `ReactiveFormConsumer` rebuilds on value and status changes; becoming
/// *touched* is neither. So in the flow that actually produces errors —
/// submit an empty form, which calls `markAllAsTouched()` — the control went
/// from untouched-invalid to touched-invalid, no rebuild happened, and nothing
/// was ever announced.
///
/// Listening to `touchChanges` as well as `statusChanged` is what makes the
/// announcement real rather than nominal. Both are needed: status covers
/// "became invalid while already touched", touch covers "was already invalid
/// and just became touched".
class _LiveErrorAnnouncer extends StatefulWidget {
  const _LiveErrorAnnouncer({
    required this.formControlName,
    required this.validationMessages,
  });

  final String formControlName;
  final Map<String, String Function(Object)> validationMessages;

  @override
  State<_LiveErrorAnnouncer> createState() => _LiveErrorAnnouncerState();
}

class _LiveErrorAnnouncerState extends State<_LiveErrorAnnouncer> {
  AbstractControl<dynamic>? _control;
  StreamSubscription<ControlStatus>? _statusSub;
  StreamSubscription<bool>? _touchSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resubscribe();
  }

  @override
  void didUpdateWidget(_LiveErrorAnnouncer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Without this, a rebuild that reuses the element but supplies a different
    // `formControlName` leaves the subscriptions pointed at the OLD control:
    // errors on the new one go unannounced, and errors on the old one announce
    // against a field the user is no longer looking at. `didChangeDependencies`
    // does not cover it — nothing inherited changed.
    if (oldWidget.formControlName != widget.formControlName) _resubscribe();
  }

  void _resubscribe() {
    final form = ReactiveForm.of(context, listen: false);
    if (form is! FormGroup) return;

    final control = form.control(widget.formControlName);
    if (identical(control, _control)) return;

    _unsubscribe();
    _control = control;
    _statusSub = control.statusChanged.listen(_onChanged);
    _touchSub = control.touchChanges.listen(_onChanged);
  }

  void _onChanged(Object? _) {
    if (mounted) setState(() {});
  }

  void _unsubscribe() {
    _statusSub?.cancel();
    _touchSub?.cancel();
    _statusSub = null;
    _touchSub = null;
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final control = _control;
    if (control == null || !control.invalid || !control.touched) {
      return const SizedBox.shrink();
    }

    final errorKey = control.errors.keys.firstOrNull;
    if (errorKey == null) return const SizedBox.shrink();

    final message = widget.validationMessages[errorKey]?.call(
      control.errors[errorKey]!,
    );
    if (message == null) return const SizedBox.shrink();

    return Semantics(
      liveRegion: true,
      label: message,
      // Not `SizedBox.shrink()`: a semantics node with an empty rect can be
      // dropped when the tree is compiled, and a dropped node announces
      // nothing. A 1×1 box keeps it in the tree at no visible cost.
      child: const SizedBox(width: 1, height: 1),
    );
  }
}
