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
///
/// A row that merges its semantics puts its `MergeSemantics` inside this
/// widget, around [child]. The merged node's rect then leaves out the gap
/// below the outline, and a nested row's indent.
class BgeOutlinedRow extends StatelessWidget {
  const BgeOutlinedRow({required this.child, super.key});

  /// The row to outline: a tile, or a tile with its actions beneath it.
  final Widget child;

  /// The corners of the outline, which a focus ring on the row follows:
  /// [BgeTokens.radiusMd].
  static BorderRadius borderRadiusOf(BuildContext context) =>
      BorderRadius.circular(BgeTokens.of(context).radiusMd);

  /// The shape the row paints around its whole child: [borderRadiusOf]
  /// corners, outlined in [BgeLineColors.rowOutline] at [BorderSide]'s
  /// default width. The tiles inside take [tileShapeOf].
  static ShapeBorder shapeOf(BuildContext context) => RoundedRectangleBorder(
    borderRadius: borderRadiusOf(context),
    side: BorderSide(color: BgeLineColors.of(context).rowOutline),
  );

  /// The shape a tile inside takes: [shapeOf]'s corners, with no outline.
  static ShapeBorder tileShapeOf(BuildContext context) =>
      RoundedRectangleBorder(borderRadius: borderRadiusOf(context));

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceSm),
    child: DecoratedBox(
      decoration: ShapeDecoration(shape: shapeOf(context)),
      child: ListTileTheme.merge(shape: tileShapeOf(context), child: child),
    ),
  );
}
