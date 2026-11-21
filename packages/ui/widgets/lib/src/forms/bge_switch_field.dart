import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:ui/src/focus/bge_row_focus_ring.dart';

/// A labelled on/off switch bound to a `FormControl<bool>`.
///
/// ## While [readOnly] it is read-only, not disabled
///
/// As `BgeTextField` and `BgeDropdownField` are (STYLE_GUIDE,
/// "In-flight forms"): drawn enabled, still in the focus order, and its value
/// still read, while nothing toggles it. A disabled switch would leave the
/// focus order mid-save, under a keyboard or screen-reader user.
///
/// To assistive tech it reads as `BgeDropdownField`'s read-only field does:
/// enabled and read-only, focusable, with no tap to offer, since a double tap
/// would toggle nothing. The keyboard's activation reaches the tile and does
/// nothing; [IgnorePointer] takes the pointer and the semantic tap. It takes
/// the focus action too, which the node here gives back, as `Focus` has it.
///
/// ## Focus through its control
///
/// It registers a reactive_forms `FocusController` with its control, on the
/// node the tile takes focus with, as `BgeTextField` and `BgeDropdownField`
/// do. So `control.focus()` reaches it, read-only or not, and a form can hand
/// focus to it (#894). A control it no longer shows, or a switch that leaves,
/// lets the controller go.
class BgeSwitchField extends StatefulWidget {
  const BgeSwitchField({
    required this.formControlName,
    required this.label,
    required this.readOnly,
    this.switchKey,
    this.subtitle,
    super.key,
  });

  final String formControlName;
  final String label;

  /// Whether nothing toggles it: set while the form saves.
  final bool readOnly;

  /// Keys the [SwitchListTile], for a test to find the switch by.
  final Key? switchKey;

  /// An optional second line under [label].
  final String? subtitle;

  @override
  State<BgeSwitchField> createState() => _BgeSwitchFieldState();
}

class _BgeSwitchFieldState extends State<BgeSwitchField> {
  // Owned here so the node can give back the focus action [IgnorePointer]
  // takes while read-only.
  final FocusNode _focusNode = FocusNode(debugLabel: 'BgeSwitchField');

  /// Registered with [_registeredWith], so `control.focus()` reaches
  /// [_focusNode]. One per control, as `ReactiveFocusableFormField` makes
  /// them: it holds the focus state of the control it was made for.
  FocusController? _focusController;
  FormControl<bool>? _registeredWith;

  static void _ignore(bool _) {}

  /// Registers a focus controller with [control], the one the switch shows,
  /// letting go of the control it showed before.
  void _focusThrough(AbstractControl<bool> control) {
    if (identical(control, _registeredWith)) return;
    _letGoOfControl();
    if (control is! FormControl<bool>) return;
    // Made on the tile's node, which it leaves for this state to dispose.
    final controller = FocusController(focusNode: _focusNode);
    control.registerFocusController(controller);
    _focusController = controller;
    _registeredWith = control;
  }

  void _letGoOfControl() {
    final controller = _focusController;
    if (controller == null) return;
    _registeredWith?.unregisterFocusController(controller);
    controller.dispose();
    _focusController = null;
    _registeredWith = null;
  }

  @override
  void dispose() {
    _letGoOfControl();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = widget.readOnly;
    final subtitle = widget.subtitle;

    return ReactiveValueListenableBuilder<bool>(
      formControlName: widget.formControlName,
      builder: (context, control, _) {
        // Here, where the control the switch shows is resolved: a new group
        // under the same name moves the controller to its control. Only a
        // listener is added, so nothing is notified mid-build.
        _focusThrough(control);
        // One node: the tile's merges into this one, which adds what
        // read-only changes.
        return MergeSemantics(
          child: Semantics(
            readOnly: readOnly,
            // As `Focus` has it: withheld on iOS (flutter/flutter#150030).
            onFocus: readOnly && defaultTargetPlatform != TargetPlatform.iOS
                ? _focusNode.requestFocus
                : null,
            child: IgnorePointer(
              ignoring: readOnly,
              child: BgeRowFocusRing(
                outsideSides: true,
                focusNode: _focusNode,
                builder: (context, row) => SwitchListTile(
                  key: widget.switchKey,
                  focusNode: row.focusNode,
                  onFocusChange: row.onFocusChange,
                  value: control.value ?? false,
                  title: Text(widget.label),
                  subtitle: subtitle == null ? null : Text(subtitle),
                  contentPadding: EdgeInsets.zero,
                  // Set while read-only too, so the tile stays enabled and
                  // focusable; a toggle then changes nothing.
                  onChanged: readOnly
                      ? _ignore
                      : (value) => control
                          ..value = value
                          ..markAsTouched(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
