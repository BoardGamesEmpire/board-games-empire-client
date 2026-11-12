import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';

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

  static void _ignore(bool _) {}

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = widget.readOnly;
    final subtitle = widget.subtitle;

    return ReactiveValueListenableBuilder<bool>(
      formControlName: widget.formControlName,
      // One node: the tile's merges into this one, which adds what read-only
      // changes.
      builder: (context, control, _) => MergeSemantics(
        child: Semantics(
          readOnly: readOnly,
          // As `Focus` has it: withheld on iOS (flutter/flutter#150030).
          onFocus: readOnly && defaultTargetPlatform != TargetPlatform.iOS
              ? _focusNode.requestFocus
              : null,
          child: IgnorePointer(
            ignoring: readOnly,
            child: SwitchListTile(
              key: widget.switchKey,
              focusNode: _focusNode,
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
  }
}
