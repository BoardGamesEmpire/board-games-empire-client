import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'live_error_announcer.dart';

/// The standard form field: an accessible text field bound to a reactive_forms
/// control (#165).
///
/// The binding, [_BoundTextField], is this package's own: reactive_forms' own
/// `ReactiveTextField` takes Flutter's Material types, which blocks #637.
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
/// - The accessible name comes from `InputDecoration.labelText` alone. An
///   extra `Semantics(label:)` wrapper looks like insurance and is actually a
///   stutter: it adds a second node with the same label, so the field
///   announces as "Email, Email".
/// - A visually-hidden **live region** announces validation errors the moment
///   they appear. Without it, a screen-reader user learns a field is invalid
///   only by navigating back onto it — which is how a form ends up feeling
///   broken rather than merely strict.
/// - The password visibility toggle meets the 48×48 minimum touch target
///   (`BgeTokens.minTapTarget`, WCAG 2.5.5).
/// - [autofillHints] enables credential-manager integration.
///
/// ## Surviving a `FormGroup` swap
///
/// Resetting a form by handing `ReactiveForm` a **new `FormGroup`** with the
/// same control names is an idiomatic `reactive_forms` move, and this widget
/// used to strand itself when it happened (#186): the swapped-away control went
/// on receiving the user's keystrokes while the new one's validation errors were
/// neither rendered nor announced — and errors raised on the dead control still
/// reached the live region, so a screen-reader user heard a complaint about a
/// form they had left.
///
/// `ReactiveFormField` **does** re-resolve its control, in
/// `didChangeDependencies` (reactive_forms 18.2.2,
/// `reactive_form_field.dart:167-177`). The reason that never fires is that
/// `_resolveFormControl` looks the group up with
/// `ReactiveForm.of(context, listen: false)`, so the element registers no
/// inherited dependency to be notified through. The rebinding code is there;
/// the notification is what is missing. Confirm that before deleting the key
/// below on the strength of seeing it.
///
/// Two things close the gap here:
///
/// - The control is resolved once, in this widget's `build`, and passed to both
///   the [_BoundTextField] (as `formControl`) and [LiveErrorAnnouncer]. Two
///   lookups of the same name would let the field and its announcer end up
///   describing different objects; one resolution makes that impossible rather
///   than merely unlikely.
/// - The [_BoundTextField] is keyed on that control. `initState` is the only
///   place `ReactiveFormField` resolves a binding that takes effect — its
///   `didChangeDependencies` would too, but never runs, per above — so a
///   changed key, which rebuilds its state, is what rebinds it.
///
/// ### Seeing the swap without paying for every keystroke
///
/// The swap is noticed through an inherited dependency on the group
/// (`ReactiveForm.of(context)`). That fires whether or not the parent rebuilt
/// this widget, so a `const` field — or one held in a `State` field and reused
/// across builds — is covered too.
///
/// The dependency on its own would be expensive. `reactive_forms` emits
/// `statusChanged` on **every** value change rather than only on a status
/// transition (`models.dart:701-703`), so it fires on every keystroke in any
/// field of the form; measured naively, one character rebuilt all three fields
/// of a three-field form. `build` therefore returns a **cached subtree** unless
/// the resolved control actually changed. A keystroke then costs one `build`
/// call and one map lookup per field, and the field subtree is left alone,
/// because returning the identical widget instance short-circuits
/// `Element.updateChild`.
///
/// The cache has three invalidation points, and dropping one is how it would
/// break: `didUpdateWidget` (this widget's own configuration), the visibility
/// toggle (`_obscure` feeds both `obscureText` and the toggle's label), and
/// `reassemble` (hot reload).
///
/// Inherited values are deliberately **not** among them. A cached subtree's
/// elements keep their own dependencies, so a theme change still reaches the
/// `TextField` without this build running. What a cache *would* swallow is an
/// inherited value read by **this** build — which is why the password toggle's
/// `BgeTokens.of` read now lives in [_VisibilityToggle]. Anything added here
/// that reads inherited data directly has to move the same way, or be added to
/// the invalidation list.
///
/// ### What rebinding costs
///
/// It **discards focus and the editing controller**: the field is being pointed
/// at a different control, so in-progress text belongs to the group that is
/// going away. It also **re-runs [autofocus]** if set — but only when the swap
/// leaves the enclosing scope with no focused child, since a scope that still
/// has one ignores the autofocus request. In a form whose fields all rebind
/// together that is the normal case, so a reset moves the caret back to the
/// autofocused field and re-opens the soft keyboard. Usually what a reset
/// should do; called out because it is a focus *movement* rather than merely a
/// loss, and `login_form` and `register_form` both set it.
///
/// No form in the repo swaps groups yet, so this is hardening slightly ahead of
/// its first caller; #179's reset-on-terminal-outcome is the expected one. Drop
/// the key once `ReactiveFormField` registers a dependency of its own.
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
  }) : assert(
         !isPassword || (obscureLabel != null && revealLabel != null),
         'A password field must be given localized obscureLabel and '
         'revealLabel strings. They are the tooltip and the screen-reader '
         'name of the visibility toggle — user-facing UI, and this package '
         'takes strings rather than owning a localization delegate. Without '
         'this assert the toggle silently shipped English on every locale.',
       );

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

  /// Localized tooltip and screen-reader label for "hide password".
  ///
  /// Required whenever [isPassword] is set — asserted in the constructor.
  /// Nullable only because it is meaningless on a non-password field.
  final String? obscureLabel;

  /// Localized tooltip and screen-reader label for "show password".
  ///
  /// Required whenever [isPassword] is set. There is deliberately no English
  /// fallback: this package takes strings rather than owning a localization
  /// delegate, and a default would let a caller ship an untranslated control
  /// without ever noticing — the failure is invisible in the developer's own
  /// locale.
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

  /// The last subtree [build] produced, served again while the resolved control
  /// is unchanged. See "Seeing the swap without paying for every keystroke" on
  /// [BgeTextField] for why this exists and what invalidates it.
  Widget? _cached;
  FormControl<String>? _cachedControl;

  @override
  void didUpdateWidget(BgeTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Invalidation point: any of this widget's own configuration may differ,
    // and the cached subtree was built from the old values.
    _cached = null;
  }

  @override
  void reassemble() {
    super.reassemble();
    // Invalidation point: hot reload must not be served a stale subtree.
    _cached = null;
  }

  @override
  Widget build(BuildContext context) {
    // `listen: true` (the default) registers an inherited dependency on the
    // enclosing group, which is what makes a swap visible even when the parent
    // hands this widget down unchanged. The cache below is what keeps that
    // affordable — see the class doc (#186).
    final form = ReactiveForm.of(context);
    // `findControl`, not `control`: the latter throws on a name the group does
    // not carry, and this runs on every build — so the decision about a missing
    // control belongs here, not to an exception escaping the lookup.
    // `findControl` also keeps dotted paths working, which a `contains` guard
    // would quietly break.
    //
    // What happens to a name that is genuinely absent is unchanged and
    // deliberate: `formControlName` goes to `_BoundTextField` below, whose
    // own resolution throws `FormControlParentNotFoundException` (no enclosing
    // form) or `FormControlNotFoundException` (no such control). Both are
    // programming errors and both should be loud; degrading to the last known
    // control would leave the user typing into something the form no longer
    // holds.
    final resolved = form is FormGroup
        ? form.findControl(widget.formControlName)
        : null;
    // A wrongly-typed control falls through to the name as well, so that
    // upstream's `BindingCastException` reports it rather than a raw cast.
    final control = resolved is FormControl<String> ? resolved : null;

    // The dependency above fires on every value change anywhere in the form,
    // not only on a swap, so most of these builds have nothing to do. Handing
    // back the identical widget instance short-circuits `Element.updateChild`,
    // leaving the field subtree untouched.
    final cached = _cached;
    if (cached != null && identical(control, _cachedControl)) return cached;

    _cachedControl = control;
    return _cached = _buildField(context, control);
  }

  Widget _buildField(BuildContext context, FormControl<String>? control) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // No enclosing `Semantics(label:, textField:)` here, deliberately.
        // `InputDecoration.labelText` already gives the field both its
        // accessible name and its textField flag; wrapping it added a SECOND
        // nested node carrying the same label, which screen readers announce
        // twice ("Email, Email"). Inherited from the auth-feature original,
        // where it read as belt-and-braces and was really a stutter.
        _BoundTextField(
          // Keyed on the resolved control: `initState` is the only place
          // `ReactiveFormField` resolves a binding that takes effect — its
          // `didChangeDependencies` would too, but never runs (see the class
          // doc) — so a changed key, which rebuilds its state, is what rebinds
          // it. Without this the field goes on editing the control of the
          // group that was swapped away.
          // `ObjectKey`, not `ValueKey`: identity is the question being asked.
          key: control == null ? null : ObjectKey(control),
          // Bound by object, not re-looked-up by name. Passing the name here
          // would have the child resolve the same control a second time, which
          // is the disagreement this widget exists to prevent; the name is the
          // fallback only when resolution failed, so upstream raises its own
          // diagnostic.
          formControl: control,
          formControlName: control == null ? widget.formControlName : null,
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
          onSubmitted: widget.onSubmitted,
          validationMessages: widget.validationMessages,
          decoration: InputDecoration(
            // Label, not hint-only. The border comes from the theme.
            labelText: widget.label,
            hintText: widget.hint,
            helperText: widget.helper,
            suffixIcon: widget.isPassword ? _visibilityToggle() : null,
          ),
        ),
        LiveErrorAnnouncer(
          control: control,
          validationMessages: widget.validationMessages,
        ),
      ],
    );
  }

  Widget _visibilityToggle() => _VisibilityToggle(
    obscured: _obscure,
    // Non-null by the constructor assert whenever `isPassword` is set, which
    // is the only path that reaches this.
    label: _obscure ? widget.revealLabel! : widget.obscureLabel!,
    onPressed: _toggleObscure,
  );

  void _toggleObscure() => setState(() {
    _obscure = !_obscure;
    // One of the cache's three invalidation points: `_obscure` feeds both
    // `obscureText` and the toggle's own label, and neither lives in a widget
    // that would rebuild on its own.
    _cached = null;
  });
}

/// The password field's show/hide control.
///
/// Extracted from [_BgeTextFieldState] for one reason: its `BgeTokens.of` read
/// has to live in its own element. That state caches its built subtree (see
/// "Seeing the swap without paying for every keystroke" on [BgeTextField]), and
/// a cache swallows inherited values the cached build read for itself. Reading
/// the tokens here means a token change rebuilds this widget directly, cache or
/// no cache.
class _VisibilityToggle extends StatelessWidget {
  const _VisibilityToggle({
    required this.obscured,
    required this.label,
    required this.onPressed,
  });

  final bool obscured;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);

    return SizedBox(
      // Explicit rather than relying on IconButton's default: the field's
      // suffix slot constrains its child, and a toggle that shrinks below
      // 48dp is a WCAG 2.5.5 failure on the control users hit most often.
      width: tokens.minTapTarget,
      height: tokens.minTapTarget,
      child: IconButton(
        icon: Icon(obscured ? Icons.visibility : Icons.visibility_off),
        tooltip: label,
        onPressed: onPressed,
      ),
    );
  }
}

/// [BgeTextField]'s binding: a [TextField] kept in step with a
/// `FormControl<String>`, both ways.
///
/// Built on `ReactiveFocusableFormField`, which is Material-free at runtime,
/// so the Material types stay in this package (#649). Its state registers the
/// `FocusController` that lets `control.focus()` reach the field, which is how
/// a rejected submit moves focus to the first invalid one (#230).
class _BoundTextField extends ReactiveFocusableFormField<String, String> {
  _BoundTextField({
    required InputDecoration decoration,
    required bool autofocus,
    required bool readOnly,
    required bool autocorrect,
    required bool enableSuggestions,
    required bool obscureText,
    required TextInputAction textInputAction,
    required TextInputType? keyboardType,
    required Iterable<String>? autofillHints,
    required int? minLines,
    required int? maxLines,
    required VoidCallback? onSubmitted,
    super.validationMessages,
    super.formControl,
    super.formControlName,
    super.key,
  }) : super(
         builder: (field) {
           final state = field as _BoundTextFieldState;
           // Merged here, not left to `TextField`, so the field's own
           // decoration carries the theme's border. The test that every field
           // takes the theme's border reads it there.
           final themed = decoration.applyDefaults(
             Theme.of(state.context).inputDecorationTheme,
           );

           return TextField(
             controller: state._controller,
             focusNode: state.focusNode,
             decoration: themed.copyWith(errorText: state.errorText),
             enabled: state.control.enabled,
             autofocus: autofocus,
             readOnly: readOnly,
             autocorrect: autocorrect,
             enableSuggestions: enableSuggestions,
             // Smart dashes and quotes follow it too: `TextField` turns them
             // off for obscured text by default.
             obscureText: obscureText,
             textInputAction: textInputAction,
             keyboardType: keyboardType,
             autofillHints: autofillHints,
             minLines: minLines,
             maxLines: maxLines,
             onChanged: state.didChange,
             onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
           );
         },
       );

  @override
  ReactiveFormFieldState<String, String> createState() =>
      _BoundTextFieldState();
}

class _BoundTextFieldState
    extends ReactiveFocusableFormFieldState<String, String> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: value ?? '');
  }

  /// A value set on the control in code, not typed here.
  ///
  /// The text lives in the controller, which a rebuild leaves alone, so the
  /// field would go on showing its old text until it is written here.
  @override
  void onControlValueChanged(dynamic value) {
    final text = value == null ? '' : value.toString();
    _controller.value = _controller.value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );

    super.onControlValueChanged(value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
