import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'package:game_catalog/l10n/game_catalog_localizations.dart';

import 'package:game_catalog/src/widgets/game_description.dart';

/// A game's description cut to its first few lines, with **More** to show
/// the rest in place and **Less** to cut it again (#707).
///
/// ## The rendered Markdown is clipped
///
/// Folded, this is the whole [GameDescription], clipped to [foldedLines]
/// lines of its body text and faded at the cut, not a plain-text excerpt.
/// Swapping an excerpt for the Markdown on More would make the text jump as
/// it opened, and the folded text would lose its formatting and links.
///
/// A screen reader hears what is drawn. Measured against the pinned Flutter:
/// under the clip, a paragraph wholly below the cut leaves the semantics
/// tree, and the paragraphs above it stay, so More reveals the rest to a
/// screen reader as it does on screen. A paragraph cut through the middle is
/// read whole. That holds only while each paragraph is a node of its own, so
/// the description asks for that itself rather than trusting its host. A
/// [MergeSemantics] above it still merges everything, and is not a host for
/// it.
///
/// ## When More shows
///
/// Only when the description is taller than the fold. The height is measured
/// as laid out, so it follows the width, the text size and an image that
/// arrives late. A description that fits shows whole with no control: it
/// will always fit, so there is nothing to disable. Once expanded, Less stays
/// whatever the height, so the button just pressed never vanishes while it
/// has focus.
///
/// The change is instant, so there is no motion for reduced motion to take
/// away.
class FoldedDescription extends StatefulWidget {
  const FoldedDescription({
    required this.markdown,
    required this.onOpenLink,
    this.foldedLines = 4,
    super.key,
  }) : assert(foldedLines > 0);

  final String markdown;

  /// Opens a link the user tapped, outside the app.
  final void Function(Uri uri) onOpenLink;

  /// How many lines of the description's body text show while folded.
  final int foldedLines;

  /// The More/Less button.
  static const Key toggleKey = Key('catalog.folded_description.toggle');

  @override
  State<FoldedDescription> createState() => _FoldedDescriptionState();
}

class _FoldedDescriptionState extends State<FoldedDescription> {
  /// Material's own body line height, 20 on 14, for a theme that sets none.
  static const double _defaultLineHeight = 1.43;

  /// How far past the fold is rounding in the text's metrics, not a line.
  /// Anything really cut is at least a line, or a block gap and a line.
  static const double _rounding = 0.5;

  bool _expanded = false;

  /// The description's laid-out height, once measured.
  double? _height;

  void _measured(double height) {
    if (!mounted || height == _height) return;
    setState(() => _height = height);
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final l10n = GameCatalogLocalizations.of(context);
    final theme = Theme.of(context);
    // GameDescription draws its paragraphs in the theme's bodyMedium
    // (MarkdownStyleSheet.fromTheme), so a line is one of those.
    final body = theme.textTheme.bodyMedium!;
    final line =
        MediaQuery.textScalerOf(context).scale(body.fontSize!) *
        (body.height ?? _defaultLineHeight);
    final fold = widget.foldedLines * line;
    final height = _height;
    final overflows = height != null && height > fold + _rounding;

    // Only the mask's opacity counts under dstIn, so the colour is any
    // opaque one. The mask, the clip and the cap stay whether folded or not,
    // and unfaded or uncapped where they have nothing to do, so neither a
    // new measurement nor More and Less changes the widgets around the
    // description, which would build it again from scratch: its images
    // would load again, and a screen reader would lose its place.
    final ink = theme.colorScheme.onSurface.withValues(alpha: 1);
    final fadeFrom = (widget.foldedLines - 1) / widget.foldedLines;
    final faded = overflows && !_expanded;
    final description = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [ink, if (faded) ink.withValues(alpha: 0) else ink],
        stops: [fadeFrom, 1],
      ).createShader(bounds),
      // Capped rather than a fixed height, so a description that fits is
      // as tall as it is from the first frame, before it has been measured.
      child: ClipRect(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: _expanded ? double.infinity : fold,
          ),
          child: OverflowBox(
            alignment: AlignmentDirectional.topStart,
            maxHeight: double.infinity,
            fit: OverflowBoxFit.deferToChild,
            child: _MeasuredHeight(
              onHeight: _measured,
              child: GameDescription(
                markdown: widget.markdown,
                onOpenLink: widget.onOpenLink,
              ),
            ),
          ),
        ),
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Each paragraph its own node, whatever the host, as the cut needs:
        // merged into one node, the paragraphs below it would be read too.
        Semantics(
          container: true,
          explicitChildNodes: true,
          child: description,
        ),
        if (_expanded || overflows)
          // Merged, so the expanded state is on the button's own node; on
          // its own it would stand as a node around the button.
          MergeSemantics(
            child: Semantics(
              expanded: _expanded,
              child: TextButton(
                key: FoldedDescription.toggleKey,
                onPressed: _toggle,
                child: Text(
                  _expanded
                      ? l10n.catalogDescriptionLess
                      : l10n.catalogDescriptionMore,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Reports its child's height after each layout that changes it.
class _MeasuredHeight extends SingleChildRenderObjectWidget {
  const _MeasuredHeight({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  _RenderMeasuredHeight createRenderObject(BuildContext context) =>
      _RenderMeasuredHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasuredHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderMeasuredHeight extends RenderProxyBox {
  _RenderMeasuredHeight(this.onHeight);

  ValueChanged<double> onHeight;

  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Layout can't rebuild the tree, so the height goes out after the frame.
    SchedulerBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}
