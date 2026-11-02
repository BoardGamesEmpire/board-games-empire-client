import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Rings what [builder] builds in the theme's [BgeTokens.focusOutlineWidth]
/// stroke while the control inside it has focus from the keyboard.
///
/// For a tappable tile or card whose own focus feedback is too faint to find,
/// as an ink's tint is over a picture, or whose edge should become the ring.
/// The ring shows as an ink's focus does: for a keyboard and not for a
/// pointer, following [FocusManager.highlightMode] as it changes.
///
/// [builder] is given the callback to pass to that control's
/// `onFocusChange`, such as [InkWell.onFocusChange].
///
/// The ring is drawn over the content, so an opaque picture can't hide it, and
/// appears and goes at once rather than fading: a focus ring that lags the
/// focus is no help, and this way it needs nothing from the motion settings.
/// The content keeps its element as the ring comes and goes.
class BgeFocusRing extends StatefulWidget {
  /// Creates a ring with the corners of [borderRadius] around what [builder]
  /// builds.
  const BgeFocusRing({
    required this.borderRadius,
    required this.builder,
    super.key,
  });

  /// The ring's corners, the same as the content's.
  final BorderRadius borderRadius;

  /// Builds the content, given the `onFocusChange` for its control.
  final Widget Function(BuildContext context, ValueChanged<bool> onFocusChange)
  builder;

  @override
  State<BgeFocusRing> createState() => _BgeFocusRingState();
}

class _BgeFocusRingState extends State<BgeFocusRing> {
  bool _hasFocus = false;

  /// Whether the ring shows: the control has focus, and by keyboard.
  bool _showRing = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_sync);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_sync);
    super.dispose();
  }

  void _onFocusChange(bool hasFocus) {
    _hasFocus = hasFocus;
    _sync();
  }

  void _sync([FocusHighlightMode? _]) {
    final show =
        _hasFocus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (mounted && show != _showRing) setState(() => _showRing = show);
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: _showRing
        ? BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: BgeTokens.of(context).focusOutlineWidth,
            ),
          )
        : const BoxDecoration(),
    child: widget.builder(context, _onFocusChange),
  );
}
