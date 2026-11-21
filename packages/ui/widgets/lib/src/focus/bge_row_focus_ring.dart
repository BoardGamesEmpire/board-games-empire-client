import 'package:flutter/material.dart';

import 'package:ui/src/focus/bge_focus_ring.dart';
import 'package:ui/src/focus/bge_pointer_focus.dart';
import 'package:ui/src/layout/bge_outlined_row.dart';

/// Rings a tappable list row while it has focus from the keyboard (#758).
///
/// For every tappable [ListTile], [CheckboxListTile], [SwitchListTile] and
/// [RadioListTile]. [builder] builds the tile, and passes it the
/// [BgeRowFocus] it is given: its `focusNode`, `onFocusChange` and
/// `focusColor`, and its `onTap` through [BgeRowFocus.onTap]. It grew out of
/// the collection list's own ringed rows (#770).
///
/// ## Focus
///
/// A list tile's only focus feedback is its ink's tint, which stands about
/// 1.3:1 from the row at rest: a keyboard user can't tell which row has
/// focus. So the tile sits in a [BgeFocusRing], drawn inside the row's box
/// with [BgeOutlinedRow.borderRadiusOf]'s corners, outlined row or not, so
/// every row looks the same. The tile's ink takes the same corners, so it
/// rounds with the ring.
///
/// The ring follows the highlight mode as it changes, and hides after a
/// mouse's or a trackpad's press anywhere until the next key press, as every
/// ring does. Focus a mouse or a trackpad gave the row draws no tint either
/// ([BgePointerFocus]): on a desktop a mouse leaves the highlight mode at the
/// keyboard's, and the row would be tinted for a user who never touched the
/// keyboard. An ink highlight keeps the strength it was first drawn with, so
/// a tint drawn hidden stays hidden after the next key press, until the
/// row's next focus. The ring shows at once, without focus moving, and is the
/// cue a keyboard user finds.
///
/// With [focusOnTap], a tap gives the row focus before the tap runs, so a
/// picker or page it opens hands focus back to it when it closes, as it does
/// after a keyboard activation. A list tile's ink takes no focus from a tap
/// of its own, and focus would land back on the page instead. Inside a
/// `BgeFocusHandoff` the pointer's focus goes with the item when it changes
/// form (#769).
///
/// A row with no tap is inert: [BgeRowFocus.onTap] keeps it null, the tile's
/// ink has no handler, and the row is no tap target and no focus stop, so no
/// ring is drawn (#44). A [CheckboxListTile], [SwitchListTile] or
/// [RadioListTile] goes inert through its own `onChanged: null` (or, for a
/// radio, its group's), where [BgeRowFocus.onTap] plays no part.
///
/// The ring is the row's own: it shows while the tile itself has focus, and
/// not while focus is on a control inside it, such as a menu button in
/// `trailing`, which draws its own.
///
/// A tile with no content padding sets [outsideSides], so the ring clears
/// the title and the icon that run to the box's sides.
///
/// A row that merges its semantics puts its `MergeSemantics` outside this
/// widget, inside any [BgeOutlinedRow]. The ring and its pointer listener add
/// no node, so the tile's tap action and words stay on one.
class BgeRowFocusRing extends StatefulWidget {
  /// Creates a ring around the row [builder] builds.
  const BgeRowFocusRing({
    required this.builder,
    this.focusNode,
    this.focusOnTap = false,
    this.outsideSides = false,
    super.key,
  });

  /// Builds the tile, given what it takes from the ring.
  final Widget Function(BuildContext context, BgeRowFocus row) builder;

  /// The tile's focus node, for a caller that moves focus to the row itself,
  /// or null for one the ring keeps.
  ///
  /// Where the ring keeps its own, a list whose rows come and go must key the
  /// ring, or an ancestor of it, by the row's record. Otherwise the node stays
  /// with the position, and focus moves to the wrong row.
  final FocusNode? focusNode;

  /// Whether a tap gives the row focus before it runs, so that what it opens
  /// hands focus back to the row.
  final bool focusOnTap;

  /// Whether the ring is drawn outside the row's box at its sides, for a
  /// tile whose content runs to them, as one with `contentPadding:
  /// EdgeInsets.zero` does. See [BgeFocusRing.outsideSides].
  final bool outsideSides;

  @override
  State<BgeRowFocusRing> createState() => _BgeRowFocusRingState();
}

/// What a ringed row's tile takes from its [BgeRowFocusRing].
@immutable
final class BgeRowFocus {
  const BgeRowFocus._({
    required this.focusNode,
    required this.onFocusChange,
    required this.focusColor,
    required this._focusOnTap,
  });

  /// The tile's `focusNode`: the one the ring was given, else the ring's own.
  final FocusNode focusNode;

  /// The tile's `onFocusChange`, which shows and hides the ring. The ring
  /// reads the row's focus from [focusNode] itself, so what this is given
  /// counts for nothing.
  final ValueChanged<bool> onFocusChange;

  /// The tile's `focusColor`: the theme's tint with no strength while the
  /// focus is a pointer's, and null otherwise, for the tile's own.
  final Color? focusColor;

  final bool _focusOnTap;

  /// The tile's `onTap` for [tap]. A null [tap] stays null, for an inert row.
  /// With [BgeRowFocusRing.focusOnTap] the row has focus when [tap] runs.
  /// Otherwise it is [tap] itself.
  VoidCallback? onTap(VoidCallback? tap) {
    if (tap == null || !_focusOnTap) return tap;
    return () {
      focusNode.requestFocus();
      // A request lands in a microtask. Applied now, the focus is the row's
      // when the tap runs, as it is after a keyboard's activation.
      FocusManager.instance.applyFocusChangesIfNeeded();
      tap();
    };
  }
}

class _BgeRowFocusRingState extends State<BgeRowFocusRing>
    with BgePointerFocus<BgeRowFocusRing> {
  /// The ring's own node, made the first time no node is given.
  FocusNode? _own;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'BgeRowFocusRing'));

  /// The node [_onNodeChange] listens to.
  FocusNode? _listened;

  /// The ring's own `onFocusChange`, from its latest build.
  ValueChanged<bool>? _ringFocusChange;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(BgeRowFocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    _listen();
  }

  /// The tile's ink reports focus anywhere inside it, a control in
  /// `trailing` too, and keeps quiet as focus moves from the tile to that
  /// control. The node itself tells of both.
  void _listen() {
    final node = _focusNode;
    if (identical(node, _listened)) return;
    _listened?.removeListener(_onNodeChange);
    _listened = node..addListener(_onNodeChange);
    // The tile's `Focus` takes up a new node without a word, so the ring
    // would keep the old one's focus until the new one's next change. A
    // first build has no ring to tell yet.
    _onNodeChange();
  }

  void _onNodeChange() =>
      _ringFocusChange?.call(_listened?.hasPrimaryFocus ?? false);

  @override
  void dispose() {
    _listened?.removeListener(_onNodeChange);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    // Every pointer's press on the row, as a list tile offers no tap-down. A
    // keyboard's activation sends none, so its focus shows. Not an inert
    // row's, which takes no focus: inside a `BgeFocusHandoff` the flag is
    // the whole item's, and would hide the tint of focus moved to another
    // control there.
    onPointerDown: (event) {
      if (_focusNode.canRequestFocus) notePointerPress(event.kind);
    },
    child: BgeFocusRing(
      borderRadius: BgeOutlinedRow.borderRadiusOf(context),
      suppressed: pointerFocus,
      outsideSides: widget.outsideSides,
      builder: (context, onFocusChange) {
        _ringFocusChange = onFocusChange;
        return ListTileTheme.merge(
          shape: BgeOutlinedRow.tileShapeOf(context),
          child: widget.builder(
            context,
            BgeRowFocus._(
              focusNode: _focusNode,
              onFocusChange: (_) => _onNodeChange(),
              focusColor: pointerFocusColor,
              focusOnTap: widget.focusOnTap,
            ),
          ),
        );
      },
    ),
  );
}
