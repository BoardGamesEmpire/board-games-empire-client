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
/// desktop is the keyboard's. So a press from one, anywhere in the app, hides
/// the ring until the next key press, as it hides every ring
/// ([BgePointerPressed], #758): focus a dialog hands back after a click, or
/// that code moves here, stays unringed. A control may also hide the ring
/// with [suppressed], as one does while its focus is a pointer's (#707).
///
/// A ring drawn over a picture sets [overPicture], and draws two tones side
/// by side (#812).
class BgeFocusRing extends StatefulWidget {
  /// Creates a ring with the corners of [borderRadius] around what [builder]
  /// builds.
  const BgeFocusRing({
    required this.borderRadius,
    required this.builder,
    this.suppressed = false,
    this.color,
    this.overPicture = false,
    this.outsideSides = false,
    super.key,
  }) : assert(
         color == null || !overPicture,
         'A ring over a picture takes its tones from pictureTonesOf, so it '
         'takes no color.',
       );

  /// The two tones of a ring over a picture: the outer stroke's, then the
  /// inner's.
  ///
  /// Artwork can be any colour, and two tones at least 9:1 apart leave one of
  /// them 3:1 from any colour beside the ring (WCAG technique C40). So the
  /// pair is `primary` and `surface` where they stand that far apart, and
  /// otherwise `onSurface` and `surface`, which do.
  static (Color outer, Color inner) pictureTonesOf(ColorScheme scheme) =>
      Wcag.contrastRatio(scheme.primary, scheme.surface) >= _pictureTonesApart
      ? (scheme.primary, scheme.surface)
      : (scheme.onSurface, scheme.surface);

  /// How far apart the two tones of a ring over a picture stand, at least.
  static const double _pictureTonesApart = 9;

  /// The ring's corners, the same as the content's.
  final BorderRadius borderRadius;

  /// Hides the ring whatever the focus and the highlight mode, for focus the
  /// caller knows a pointer gave. The ring follows the focus again as soon as
  /// this is false.
  final bool suppressed;

  /// The ring's colour, or null for the scheme's `primary`.
  ///
  /// Give it where the control sits on something other than a surface, which
  /// `primary` was never solved against: pass a colour that holds 3:1 there.
  final Color? color;

  /// Whether the ring is drawn over a picture, which can be any colour.
  ///
  /// Such a ring draws [pictureTonesOf]'s outer tone in a
  /// [BgeTokens.focusOutlineWidth] stroke on the edge, and the inner tone in
  /// a second stroke as wide just inside it, so the ring reaches twice that
  /// width in. Where the content leaves a [BgeTokens.focusRingGap] margin
  /// inside the ring, as the cover's expansions badge does, the inner stroke
  /// fills it while that gap is as wide as a [BgeTokens.focusOutlineWidth]
  /// stroke, as the tokens are now. A wider gap would leave picture showing
  /// between the inner stroke and the content. A ring on a theme's surfaces
  /// holds its contrast through the palette, so it leaves this false and
  /// draws one stroke.
  ///
  /// The tones are the picture's, so a ring over a picture takes no [color]:
  /// one colour given for a single stroke can't keep both tones 9:1 apart.
  /// Giving both fails an assert.
  final bool overPicture;

  /// Whether the ring is drawn outside the content's box at its sides, by
  /// the ring's own width, rather than on the box's edge.
  ///
  /// For content that runs to its box's sides, as a list tile with no
  /// content padding does: a ring on the edge would cover the first glyph of
  /// its title, or its icon's edge. The top and bottom stay on the edge,
  /// where a tile centres its content. Nothing clips the ring to the box, so
  /// the content needs that much room either side, which the page's, the
  /// sheet's or the dialog's padding gives.
  final bool outsideSides;

  /// Builds the content, given the `onFocusChange` for its control.
  final Widget Function(BuildContext context, ValueChanged<bool> onFocusChange)
  builder;

  @override
  State<BgeFocusRing> createState() => _BgeFocusRingState();
}

class _BgeFocusRingState extends State<BgeFocusRing> {
  bool _hasFocus = false;

  /// Whether the ring shows: the control has focus, by keyboard, and no
  /// mouse has pressed since the last key press.
  bool _showRing = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_sync);
    BgePointerPressed.attach();
    BgePointerPressed.listenable.addListener(_sync);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_sync);
    BgePointerPressed.listenable.removeListener(_sync);
    BgePointerPressed.detach();
    super.dispose();
  }

  void _onFocusChange(bool hasFocus) {
    _hasFocus = hasFocus;
    _sync();
  }

  void _sync([FocusHighlightMode? _]) {
    final show =
        _hasFocus &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
        !BgePointerPressed.value;
    if (mounted && show != _showRing) setState(() => _showRing = show);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _showRing && !widget.suppressed;
    final width = BgeTokens.of(context).focusOutlineWidth;
    final scheme = Theme.of(context).colorScheme;
    final outset = widget.outsideSides ? width : 0.0;
    final Color outer;
    final Color? inner;
    if (widget.overPicture) {
      (outer, inner) = BgeFocusRing.pictureTonesOf(scheme);
    } else {
      (outer, inner) = (widget.color ?? scheme.primary, null);
    }
    // Two boxes whether or not the ring shows or has two tones, so that the
    // content keeps its element as either changes. The inner tone is drawn
    // twice the stroke wide, under the outer stroke, which covers its outer
    // half: what shows is a stroke just inside the outer one, with its
    // corners shrunk by the stroke's width.
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: shown
          ? _RingDecoration(
              borderRadius: widget.borderRadius,
              border: Border.all(color: outer, width: width),
              sidesOutset: outset,
            )
          : const _RingDecoration(),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: shown && inner != null
            ? _RingDecoration(
                borderRadius: widget.borderRadius,
                border: Border.all(color: inner, width: width * 2),
                sidesOutset: outset,
              )
            : const _RingDecoration(),
        child: widget.builder(context, _onFocusChange),
      ),
    );
  }
}

/// A [BoxDecoration] that a press goes through. A [DecoratedBox] takes a
/// press anywhere its decoration covers, so a plain one would claim it on the
/// margin between the ring and its content, and a caller that sends a missed
/// press on elsewhere, as the game detail's chip tap target sends it to the
/// chip, would never see the miss (#708).
///
/// With [sidesOutset], it paints that far outside the box at its left and
/// right, for [BgeFocusRing.outsideSides].
class _RingDecoration extends BoxDecoration {
  const _RingDecoration({
    super.border,
    super.borderRadius,
    this.sidesOutset = 0,
  });

  /// How far outside the box, at each side, the decoration paints.
  final double sidesOutset;

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      false;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) {
    final painter = super.createBoxPainter(onChanged);
    return sidesOutset == 0
        ? painter
        : _SidesOutsetPainter(painter, sidesOutset, onChanged);
  }

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is _RingDecoration &&
      other.sidesOutset == sidesOutset;

  @override
  int get hashCode => Object.hash(super.hashCode, sidesOutset);
}

/// Paints [_inner] over a box widened by [_outset] at each side.
class _SidesOutsetPainter extends BoxPainter {
  _SidesOutsetPainter(this._inner, this._outset, super.onChanged);

  final BoxPainter _inner;
  final double _outset;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    _inner.paint(
      canvas,
      offset.translate(-_outset, 0),
      size == null
          ? configuration
          : configuration.copyWith(
              size: Size(size.width + 2 * _outset, size.height),
            ),
    );
  }

  @override
  void dispose() {
    _inner.dispose();
    super.dispose();
  }
}
