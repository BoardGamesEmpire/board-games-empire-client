import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Builds the button a [BgeInertButton] wraps, from the focus node and the
/// press handler it must use.
typedef BgeInertButtonBuilder = Widget Function(
  BuildContext context,
  FocusNode focusNode,
  VoidCallback onPressed,
);

/// A button that stays enabled while it can do nothing, so it keeps focus,
/// and says to a screen reader that it is not available (#607).
///
/// A disabled Material button cannot hold focus: `ButtonStyleButton` passes
/// `canRequestFocus: enabled`, so a button that disables itself under a
/// keyboard or screen-reader user drops their place. This one stays enabled
/// while [inert]. A press then does nothing, and the button builds its own
/// semantics node in place of the Material one: not enabled, with no tap
/// action, but still focusable and reporting its focus. It is the same node
/// inert or not, so a screen reader's cursor stays put when the state
/// flips; at rest it reads as the plain button would.
///
/// Use it for a control whose own press makes it inert for a while: a retry
/// while the pass it started runs, a menu while the write it chose runs, a
/// row's arrow at the end it moves towards. A control that is unavailable
/// for a reason no press of its own causes, such as being offline (#49), is
/// disabled instead.
///
/// [builder] gets the focus node and the press handler to give the button.
/// The handler ignores a press while [inert], so the button can always be
/// enabled. Its look while inert, a spinner or a muted style, is the
/// caller's.
class BgeInertButton extends StatefulWidget {
  const BgeInertButton({
    required this.inert,
    required this.label,
    required this.onPressed,
    required this.builder,
    this.expanded,
    this.ignoreKeyRepeats = true,
    super.key,
  });

  /// Whether a press does nothing now.
  final bool inert;

  /// The node's name. A caller whose button is busy passes the in-progress
  /// string, so the name says why it is not available.
  final String label;

  /// What a press does while not [inert].
  final VoidCallback onPressed;

  /// For a button that opens a menu: whether the menu is open.
  final bool? expanded;

  /// Whether a held Enter or Space activates the button once, not once per
  /// key repeat.
  ///
  /// True for a button whose press starts work that makes it inert: the
  /// repeats still arriving when that work ends would start it again, or
  /// open and close a menu with each one. A press is one key-down. False
  /// where holding the key down to repeat the press is the point, as on a
  /// row's arrows.
  final bool ignoreKeyRepeats;

  final BgeInertButtonBuilder builder;

  @override
  State<BgeInertButton> createState() => _BgeInertButtonState();
}

class _BgeInertButtonState extends State<BgeInertButton> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'BgeInertButton',
    onKeyEvent: _ignoreActivationRepeat,
  );

  static final _activationKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
  };

  KeyEventResult _ignoreActivationRepeat(FocusNode _, KeyEvent event) =>
      widget.ignoreKeyRepeats &&
          event is KeyRepeatEvent &&
          _activationKeys.contains(event.logicalKey)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;

  void _press() {
    if (!widget.inert) widget.onPressed();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inert = widget.inert;

    return ListenableBuilder(
      listenable: _focusNode,
      builder: (context, button) => Semantics(
        container: true,
        button: true,
        enabled: !inert,
        expanded: widget.expanded,
        focused: _focusNode.hasPrimaryFocus,
        label: widget.label,
        onTap: inert ? null : widget.onPressed,
        // As `Focus` has it: withheld on iOS (flutter/flutter#150030).
        onFocus: defaultTargetPlatform == TargetPlatform.iOS
            ? null
            : _focusNode.requestFocus,
        excludeSemantics: true,
        child: button,
      ),
      child: widget.builder(context, _focusNode, _press),
    );
  }
}
