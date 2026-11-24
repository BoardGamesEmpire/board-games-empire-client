import 'package:flutter/material.dart';
import 'package:game_filters/game_filters.dart';

/// A platform the user owns a game on: a chip filled in `primary`, with a
/// check and its name in `onPrimary` (#708). The detail page's and the quick
/// look's, so the two look alike (#799).
///
/// The check and [semanticsLabel] carry the meaning, so the fill is never the
/// only sign. `game_detail_platforms_contrast_test` holds the pair to
/// contrast.
///
/// With [onPressed] it is an [ActionChip], as on the page, where it opens the
/// user's copy. Without, it is a plain [Chip] that does nothing, as in the
/// quick look. Either is built without the padding out to the tap target, so
/// the caller sets the target: see the page's `_ChipSlot`.
class OwnedPlatformChip extends StatelessWidget {
  const OwnedPlatformChip({
    required this.name,
    required this.semanticsLabel,
    this.onPressed,
    this.focusNode,
    super.key,
  });

  /// The check's size: a Material chip's avatar size.
  static const double checkSize = 18;

  /// The platform's name, as shown.
  final String name;

  /// What a screen reader hears in place of [name]. It goes on the label,
  /// where it replaces the shown name in the chip's own node, which keeps
  /// the chip's press and focus for a screen reader.
  final String semanticsLabel;

  /// Null for a chip with no action.
  final VoidCallback? onPressed;

  /// The chip's focus node, where it has [onPressed].
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = Icon(Icons.check, size: checkSize, color: scheme.onPrimary);
    final label = GameFilterChipLabel(name, semanticsLabel: semanticsLabel);
    final labelStyle = TextStyle(color: scheme.onPrimary);
    // Its own side keeps the theme's chip ring (#761) off the fill. Where the
    // chip takes focus, its caller rings it.
    const side = BorderSide.none;
    final onPressed = this.onPressed;
    if (onPressed == null) {
      return Chip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: avatar,
        label: label,
        labelStyle: labelStyle,
        backgroundColor: scheme.primary,
        side: side,
      );
    }
    return ActionChip(
      focusNode: focusNode,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      avatar: avatar,
      label: label,
      labelStyle: labelStyle,
      backgroundColor: scheme.primary,
      side: side,
      onPressed: onPressed,
    );
  }
}
