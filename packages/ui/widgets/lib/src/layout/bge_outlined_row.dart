import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A list row outlined in the `rowOutline` role, with room beneath it (#647).
///
/// The outline goes around the whole row: [shapeOf], painted behind [child],
/// so a record's actions under its tile sit inside it. Any [ListTile],
/// [CheckboxListTile] or [SwitchListTile] inside takes [tileShapeOf], the same
/// corners without the outline, so its ink splash rounds with the outline and
/// the tile draws no border of its own. [BgeTokens.spaceSm] is left between
/// one row and the next.
///
/// The outline is painted behind the child, not over it, so the keyboard
/// focus ring on the tile's edge (`BgeFocusRing`) is drawn above it. A child
/// with an opaque fill of its own would hide the outline.
///
/// For rows that each stand for one record on a list screen. Settings rows,
/// drawer rows, a detail page's action rows, sheets and dialogs, and event
/// rows (which are separated by a divider) stay plain.
///
/// A nested row's caller indents outside this widget, so the outline starts
/// at the indent.
class BgeOutlinedRow extends StatelessWidget {
  const BgeOutlinedRow({required this.child, super.key});

  /// The row to outline: a tile, or a tile with its actions beneath it.
  final Widget child;

  /// The shape every row inside takes: [BgeTokens.radiusMd] corners, outlined
  /// in [BgeLineColors.rowOutline] at [BorderSide]'s default width.
  static ShapeBorder shapeOf(BuildContext context) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(BgeTokens.of(context).radiusMd),
    side: BorderSide(color: BgeLineColors.of(context).rowOutline),
  );

  /// The shape a tile inside takes: [shapeOf]'s corners, with no outline.
  static ShapeBorder tileShapeOf(BuildContext context) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BgeTokens.of(context).radiusMd),
      );

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceSm),
    child: DecoratedBox(
      decoration: ShapeDecoration(shape: shapeOf(context)),
      child: ListTileTheme.merge(shape: tileShapeOf(context), child: child),
    ),
  );
}
