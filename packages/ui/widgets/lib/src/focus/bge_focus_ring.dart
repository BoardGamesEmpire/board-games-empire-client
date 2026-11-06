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
/// The content keeps its element as the ring comes and goes. It takes no
/// press of its own, shown or not: where the content leaves a margin inside
/// the ring, a press there hits nothing in it.
///
/// A mouse or a trackpad leaves the highlight mode as it was, which on a
/// desktop is the keyboard's, so a control that takes focus from a click would
/// be ringed by it. Such a control hides the ring with [suppressed] while its
/// focus is a pointer's (#707).
class BgeFocusRing extends StatefulWidget {
  /// Creates a ring with the corners of [borderRadius] around what [builder]
  /// builds.
  const BgeFocusRing({
    required this.borderRadius,
    required this.builder,
    this.suppressed = false,
    super.key,
  });

  /// The ring's corners, the same as the content's.
  final BorderRadius borderRadius;

  /// Hides the ring whatever the focus and the highlight mode, for focus the
  /// caller knows a pointer gave. The ring follows the focus again as soon as
  /// this is false.
  final bool suppressed;

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
    decoration: _showRing && !widget.suppressed
        ? _RingDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: BgeTokens.of(context).focusOutlineWidth,
            ),
          )
        : const _RingDecoration(),
    child: widget.builder(context, _onFocusChange),
  );
}

/// A [BoxDecoration] that a press goes through. A [DecoratedBox] takes a
/// press anywhere its decoration covers, so a plain one would claim it on the
/// margin between the ring and its content, and a caller that sends a missed
/// press on elsewhere, as the game detail's chip tap target sends it to the
/// chip, would never see the miss (#708).
class _RingDecoration extends BoxDecoration {
  const _RingDecoration({super.border, super.borderRadius});

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      false;
}
