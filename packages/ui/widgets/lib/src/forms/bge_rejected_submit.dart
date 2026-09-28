import 'dart:async';

import 'package:flutter/material.dart' show InputDecorator;
import 'package:flutter/widgets.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What a form does with a submit it refuses (#230).
///
/// ```dart
/// void _submit() {
///   if (!_form.valid) {
///     _form.rejectSubmit();
///     return;
///   }
///   ...
/// }
/// ```
///
/// ## Why marking touched is not enough
///
/// `markAllAsTouched` renders every error, wherever the fields happen to be.
/// A user who scrolled down to reach the submit button is no longer looking
/// at them. Measured at 320×480 and 200% text, a rejected register left its
/// first error 145dp above the viewport, and compose left its first invalid
/// control 157dp above it. From where the user stands, the button did
/// nothing. That is #209's failure, arriving through validation instead of
/// the network.
///
/// ## Why focus, rather than only a reveal
///
/// Focus puts a keyboard or screen-reader user on the field that needs them,
/// not just the eye. A reveal alone would leave them holding the submit
/// button, with the message somewhere behind them. `ServerAddForm` already did
/// this for its URL field; this is that, for every form.
///
/// ## Why it still reveals
///
/// Focus alone does not show the field. A **dropdown** is not scrolled to at
/// all: measured on compose before this existed, focusing its severity
/// dropdown moved focus and left the page where it was, with the field still
/// above the viewport. A **text field** scrolls itself only as far as its
/// caret needs, and at 200% text that left the field's floating label 7dp
/// above the viewport — the one line that says which field is wrong.
///
/// So the whole decorated field — label, input and error — is shown on
/// screen here, with one spacing step of room, which is what a revealed
/// `BgeInlineBanner` gets.
///
/// A text field still runs its caret reveal on the same focus change, and
/// both animate, so the one that starts second cancels the first. This one
/// is made to start second — see [rejectSubmit] — and the region it reveals
/// contains the caret's, so the caret is in view when it lands. Started
/// first, it was cancelled before it moved, and the label stayed clipped.
extension BgeRejectedSubmit on FormGroup {
  /// Marks every control touched, so each error renders, then moves focus to
  /// the first invalid control and brings it into view.
  ///
  /// **"First" is declaration order**, depth-first through nested groups and
  /// arrays. That is the visual order on every form here. A form whose
  /// controls are declared out of the order they render would focus the wrong
  /// field, so declare them in render order.
  ///
  /// A disabled control is never invalid, so a field hidden by disabling its
  /// control, like compose's severity on a feature request, is passed over.
  ///
  /// With no widget bound to the control, this only marks the controls
  /// touched.
  void rejectSubmit() {
    markAllAsTouched();

    final control = _firstInvalid(this);
    if (control == null) return;
    control.focus();

    final node = control.focusController?.focusNode;
    if (node == null || node.context == null) return;
    // Post-frame, because the errors `markAllAsTouched` just rendered change
    // the layout and the reveal has to measure the field where it will be.
    //
    // Registered from a microtask, because of the order it has to run in. The
    // focus change lands on a microtask that `focus()` has already queued, and
    // that is where a text field schedules its caret reveal. Queued behind it,
    // this reveal runs after the caret's in the same frame, cancels it before
    // it has moved, and lands the whole field instead.
    scheduleMicrotask(
      () => WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(node)),
    );
  }
}

/// The first invalid leaf under [control], depth-first in declaration order.
FormControl<dynamic>? _firstInvalid(AbstractControl<dynamic> control) {
  if (!control.invalid) return null;
  if (control is FormControl<dynamic>) return control;
  final children = switch (control) {
    FormGroup(:final controls) => controls.values,
    FormArray<dynamic>(:final controls) => controls,
    _ => const <AbstractControl<dynamic>>[],
  };
  for (final child in children) {
    final found = _firstInvalid(child);
    if (found != null) return found;
  }
  return null;
}

/// Shows the focused control on screen, with a spacing step of room above
/// and below it.
///
/// `showOnScreen` rather than `Scrollable.ensureVisible`, for two reasons.
/// It moves the page only as far as it has to, in either direction, and
/// leaves a page that already shows the field alone. A submit from a pinned
/// footer does not scroll the content, so the first error can sit on either
/// side of the viewport, and each `ensureVisible` alignment policy handles
/// only one. It also walks out through every enclosing scroll view, so a
/// field is not revealed inside a scroller that is itself off screen.
///
/// What gets revealed is the field's `InputDecorator`, which holds the label
/// and the error as well as the input. A text field's focus node sits on its
/// input line, inside the decorator, so the decorator is found above it. A
/// dropdown form field's focus node sits above its decorator and already
/// wraps all of it, so that box is used as it is.
void _reveal(FocusNode node) {
  final context = node.context;
  if (context == null || !context.mounted) return;
  final box =
      _decoratorAbove(context)?.findRenderObject() ??
      context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return;

  final tokens = BgeTokens.of(context);
  final inset = tokens.spaceMd;
  box.showOnScreen(
    rect: Rect.fromLTRB(0, -inset, box.size.width, box.size.height + inset),
    // `showOnScreen` jumps when handed a zero duration, so reduced motion is
    // honoured without a branch here.
    duration: BgeMotion.durationOf(context, tokens.motionShort),
    curve: BgeMotion.enter,
  );
}

/// The nearest `InputDecorator` enclosing [context], if any.
Element? _decoratorAbove(BuildContext context) {
  Element? found;
  context.visitAncestorElements((element) {
    if (element.widget is InputDecorator) found = element;
    return found == null;
  });
  return found;
}
