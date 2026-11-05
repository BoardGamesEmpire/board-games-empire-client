import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:ui_tokens/src/bge_tokens.dart';

/// Where a button's focus ring sits against the button's shape (#644).
enum BgeButtonFocusRingPlacement {
  /// [BgeTokens.focusRingGap] outside the shape, so the ring touches only the
  /// surface around the button and never its fill.
  ///
  /// Only for a button that doesn't clip to its shape. Flutter clips a
  /// button once its style has a builder, unless its constructor passes
  /// `Clip.none` (the filled, tonal and icon buttons do), and an outside
  /// ring under that clip is cut away whole.
  ///
  /// The ring reaches `focusRingGap + focusOutlineWidth` past the button's
  /// shape. The button's tap-target padding holds that where the shape is
  /// under 48dp (above and below a filled button, all round an icon button),
  /// but not beside a filled button, nor above and below one taller than
  /// 48dp, as at 2.0 text. A clip that close, such as a scroll view's edge
  /// with no padding or a clipping card, cuts the ring there.
  outside,

  /// Inside the shape's edge, with no gap: for a button that clips, and
  /// whose own background is a surface, which `primary` holds 3:1 against.
  inside,
}

/// The keyboard focus ring `BgeTheme` gives the filled, tonal, icon, text,
/// outlined and elevated buttons (#644).
///
/// Not yet the other Material controls: `SegmentedButton` builds its segments'
/// style without the theme's builder, and floating action buttons, list rows,
/// chips and drawer entries aren't these buttons. `ACCESSIBILITY_AUDIT.md`
/// lists each in its findings.
///
/// Material 3's only focus feedback on a button is a faint tint, which a
/// keyboard user can lose. This ring is [colorOf] the scheme,
/// [BgeTokens.focusOutlineWidth] wide, and follows the button's shape. It
/// shows while the button has focus and the highlight mode is the
/// keyboard's, so a touch or a focus that comes back with no key pressed
/// (a dialog closing on a phone) draws none, and it follows the highlight
/// mode as that changes while the button keeps focus.
///
/// A mouse or a trackpad leaves the highlight mode as it was, which on a
/// desktop is the keyboard's. So a press from one, anywhere in the app, hides
/// every button's ring until the next key press, as a browser's
/// `:focus-visible` does. Focus that then lands on a button the mouse never
/// pressed stays unringed too: handed back as a dialog closes, given to a
/// button that autofocuses, or moved there in code.
///
/// A button that sets its own shape passes it here, in its style's
/// `backgroundBuilder`, or the theme's ring would follow the theme's shape
/// rather than the button's.
abstract final class BgeButtonFocusRing {
  /// One builder per shape and placement for a ring in the scheme's colour,
  /// so a style built in a `build` method compares equal from one build to
  /// the next, and so do two themes built from one palette, and a theme
  /// animation lerps between equal builders: `ButtonStyle` compares its
  /// builders by identity.
  ///
  /// A builder with a colour of its own is not kept. That colour can be one
  /// frame of a light/dark animation, a banner's foreground lerped, and
  /// keeping one per colour would keep every frame's. Such a style compares
  /// unequal from one build to the next, which costs its button a rebuild
  /// when its parent rebuilds anyway.
  static final _builders =
      <(OutlinedBorder, BgeButtonFocusRingPlacement), ButtonLayerBuilder>{};

  /// The `ButtonStyle.backgroundBuilder` that rings a button in [shape], at
  /// [placement].
  ///
  /// [placement] has no default: [BgeButtonFocusRingPlacement.outside] on a
  /// button that clips draws nothing at all.
  ///
  /// The ring is [colorOf] the ambient scheme unless [color] is given. Give
  /// it where a button sits on something other than a surface, such as a
  /// banner's toned container, which `primary` was never solved against: pass
  /// the colour drawn on that container, which holds the contrast there.
  static ButtonLayerBuilder builder(
    OutlinedBorder shape, {
    required BgeButtonFocusRingPlacement placement,
    Color? color,
  }) {
    ButtonLayerBuilder build() =>
        (context, states, child) => _BgeButtonFocusRing(
          shape: shape,
          placement: placement,
          color: color,
          focused: states.contains(WidgetState.focused),
          child: child,
        );
    return color == null
        ? _builders.putIfAbsent((shape, placement), build)
        : build();
  }

  /// How many builders are kept, for a test that none piles up.
  @visibleForTesting
  static int get debugCachedBuilderCount => _builders.length;

  /// The role the ring is drawn in.
  static Color colorOf(ColorScheme scheme) => scheme.primary;
}

class _BgeButtonFocusRing extends StatefulWidget {
  const _BgeButtonFocusRing({
    required this.shape,
    required this.placement,
    required this.color,
    required this.focused,
    required this.child,
  });

  final OutlinedBorder shape;
  final BgeButtonFocusRingPlacement placement;

  /// The ring's colour, or null for the scheme's.
  final Color? color;

  /// Whether the button has focus, by any means: `WidgetState.focused`
  /// ignores the highlight mode.
  final bool focused;

  final Widget? child;

  @override
  State<_BgeButtonFocusRing> createState() => _BgeButtonFocusRingState();
}

class _BgeButtonFocusRingState extends State<_BgeButtonFocusRing> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChange);
    _PointerLastPressed.instance
      ..attach()
      ..addListener(_onPointerLastPressedChange);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChange);
    _PointerLastPressed.instance
      ..removeListener(_onPointerLastPressedChange)
      ..detach();
    super.dispose();
  }

  // The button doesn't rebuild when only the highlight mode changes, so the
  // ring listens for itself. Only a focused button's ring can change.
  void _onHighlightModeChange(FocusHighlightMode _) {
    if (widget.focused) setState(() {});
  }

  void _onPointerLastPressedChange() {
    if (widget.focused) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final shown =
        widget.focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
        !_PointerLastPressed.instance.value;
    return CustomPaint(
      foregroundPainter: BgeButtonFocusRingPainter(
        shape: widget.shape,
        placement: widget.placement,
        color: shown
            ? widget.color ??
                  BgeButtonFocusRing.colorOf(Theme.of(context).colorScheme)
            : null,
        width: tokens.focusOutlineWidth,
        gap: tokens.focusRingGap,
        textDirection: Directionality.maybeOf(context),
      ),
      child: widget.child,
    );
  }
}

/// Whether a mouse's or a trackpad's press came after the last key press,
/// anywhere in the app, which hides every ring: one flag for the app, as a
/// browser keeps one for the page to decide `:focus-visible` (#644).
///
/// Watches pointers and keys only while some ring is built, and forgets the
/// press once none is, so an app with no button on screen holds no handlers.
class _PointerLastPressed extends ValueNotifier<bool> {
  _PointerLastPressed() : super(false);

  static final instance = _PointerLastPressed();

  /// How many rings are built.
  int _rings = 0;

  void attach() {
    if (_rings++ > 0) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void detach() {
    if (--_rings > 0) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    value = false;
  }

  /// Only a mouse's or a trackpad's press. A touch or a stylus turns the
  /// highlight mode to touch, which hides the ring already, and a mouse's
  /// hover, wheel or trackpad scroll isn't a press.
  void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    if (event.kind
        case PointerDeviceKind.touch ||
            PointerDeviceKind.stylus ||
            PointerDeviceKind.invertedStylus) {
      return;
    }
    value = true;
  }

  /// The user is at the keyboard again. A shortcut held with Control, Alt or
  /// Meta isn't navigation, as a browser's `:focus-visible` has it.
  bool _onKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed) {
      value = false;
    }
    return false;
  }
}

/// Paints a button's focus ring. Public for tests to find; not API.
@visibleForTesting
class BgeButtonFocusRingPainter extends CustomPainter {
  /// Creates a painter for a ring in [color] that follows [shape].
  BgeButtonFocusRingPainter({
    required this.shape,
    required this.placement,
    required this.color,
    required this.width,
    required this.gap,
    this.textDirection,
  });

  /// The button's shape, which the ring follows.
  final OutlinedBorder shape;

  /// Where the ring sits against [shape].
  final BgeButtonFocusRingPlacement placement;

  /// The ring's colour, or null while no ring shows.
  final Color? color;

  /// The ring's stroke width.
  final double width;

  /// How far outside [shape] an outside ring sits.
  final double gap;

  /// For a shape with directional corners.
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final color = this.color;
    if (color == null) return;
    final bounds = Offset.zero & size;
    switch (placement) {
      case BgeButtonFocusRingPlacement.outside:
        shape
            .copyWith(
              side: BorderSide(
                color: color,
                width: width,
                strokeAlign: BorderSide.strokeAlignOutside,
              ),
            )
            .paint(canvas, bounds.inflate(gap), textDirection: textDirection);
      case BgeButtonFocusRingPlacement.inside:
        // A border's stroke is inside its shape by default.
        shape
            .copyWith(
              side: BorderSide(color: color, width: width),
            )
            .paint(canvas, bounds, textDirection: textDirection);
    }
  }

  @override
  bool shouldRepaint(BgeButtonFocusRingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.shape != shape ||
      oldDelegate.placement != placement ||
      oldDelegate.width != width ||
      oldDelegate.gap != gap ||
      oldDelegate.textDirection != textDirection;
}
