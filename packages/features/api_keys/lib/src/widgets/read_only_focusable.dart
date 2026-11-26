import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A control that stays drawn enabled, in the focus order and read while
/// [readOnly], while nothing changes it (#1028; STYLE_GUIDE, "In-flight
/// forms"). It reads as `BgeSwitchField`'s read-only switch does: read-only
/// and focusable, with no tap to offer.
///
/// The control [builder] builds takes the focus node it is given, and
/// ignores every change while [readOnly] through a callback that is never
/// null, so it stays enabled. [IgnorePointer] takes the pointer and the
/// semantic tap then, and with them the focus action, which this widget's
/// node gives back through the owned focus node.
///
/// The control's node merges into this one, which adds what read-only
/// changes, so the two are read as one.
///
/// The scope picker's rows and the expiry control's chips are its two users.
class ReadOnlyFocusable extends StatefulWidget {
  const ReadOnlyFocusable({
    required this.readOnly,
    required this.debugLabel,
    required this.builder,
    super.key,
  });

  /// Whether nothing changes the control, as while a save is on its way.
  final bool readOnly;

  /// Names the focus node, for debugging.
  final String debugLabel;

  /// Builds the control on the focus node this widget owns.
  final Widget Function(BuildContext context, FocusNode focusNode) builder;

  @override
  State<ReadOnlyFocusable> createState() => _ReadOnlyFocusableState();
}

class _ReadOnlyFocusableState extends State<ReadOnlyFocusable> {
  // Owned here so the node can give back the focus action [IgnorePointer]
  // takes while read-only.
  late final FocusNode _focusNode = FocusNode(debugLabel: widget.debugLabel);

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = widget.readOnly;
    // One node: the control's merges into this one, which adds what
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
          child: widget.builder(context, _focusNode),
        ),
      ),
    );
  }
}
