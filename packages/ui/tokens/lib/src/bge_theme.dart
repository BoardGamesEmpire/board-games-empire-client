import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/bge_button_focus_ring.dart';
import 'package:ui_tokens/src/accessibility/bge_chip_focus.dart';
import 'package:ui_tokens/src/accessibility/bge_navigation_focus.dart';
import 'package:ui_tokens/src/accessibility/bge_pointer_pressed.dart';
import 'package:ui_tokens/src/accessibility/bge_segment_focus.dart';
import 'package:ui_tokens/src/accessibility/bge_selection.dart';
import 'package:ui_tokens/src/bge_line_colors.dart';
import 'package:ui_tokens/src/bge_palette.dart';
import 'package:ui_tokens/src/bge_status_colors.dart';
import 'package:ui_tokens/src/bge_tokens.dart';
import 'package:ui_tokens/src/bge_typography.dart';

/// The minimum dialog width, where the window has room for it: Flutter's own
/// default, restated (#207).
///
/// `DialogThemeData.constraints` replaces Flutter's default
/// `BoxConstraints(minWidth: 280)` rather than adding to it, so a theme that
/// caps dialog width also drops the minimum unless it says it again. Without
/// it, a short confirmation shrinks to the width of its title. In a window
/// narrower than 360 (the minimum plus the 40dp insets), it gives way to the
/// window.
///
/// Not a token: it is not a width decision this design system makes, and
/// nobody is meant to tune it. Named rather than inline for the reason
/// `BgeTextField`'s semantics anchor is: a literal would need a file-wide
/// exemption from the enforcement test's width rule, which would then wave
/// through every later literal width in this file.
const double _dialogMinWidth = 280;

/// The most lines a field's helper or error takes before it is ellipsized
/// (#499).
///
/// Five lines fit the app's longest two-sentence field error ("Plain http is
/// only allowed for local and private network addresses. Use https for this
/// server.") at 320dp and 2.0 text, measured with real fonts. The sixth is
/// room for a translation that runs longer. Capped rather than unlimited, so a
/// runaway message can't push the rest of a form out of reach.
const int _fieldMessageMaxLines = 6;

/// Every Material button's shape (#644).
///
/// Material 3's default, set explicitly so a button and its focus ring share
/// one shape, and can't drift apart when the buttons' shape changes (#645).
const OutlinedBorder _buttonShape = StadiumBorder();

/// A button theme's style: the one shape, and the focus ring at [placement].
///
/// The builder also makes Flutter clip a `TextButton()`, `OutlinedButton()` or
/// `ElevatedButton()` to its shape, content and all (#644). A label that
/// wraps to two lines reaches the stadium's curved ends and loses glyph
/// pixels there: at 320dp and 2.0 text, "Loading more games…" lost a 4 by 4
/// block off its "L" and off its "g"'s descender (#764, pinned by a
/// skipped test in `bge_button_focus_ring_test.dart`).
ButtonStyle _buttonStyle(BgeButtonFocusRingPlacement placement) => ButtonStyle(
  shape: const WidgetStatePropertyAll(_buttonShape),
  backgroundBuilder: BgeButtonFocusRing.builder(
    _buttonShape,
    placement: placement,
  ),
);

/// The four application themes (#32), built from a [BgePalette] with the
/// theme-level accessibility baseline applied uniformly.
///
/// Baseline decisions (all test-enforced in `bge_theme_test.dart`):
///
/// - **Tap targets ≥ 48dp** — `MaterialTapTargetSize.padded` on every
///   platform. Deliberately *not* `.shrinkWrap`-on-desktop: pointer
///   precision does not remove the motor-accessibility need.
/// - **`VisualDensity.standard`** — deliberately *not*
///   `adaptivePlatformDensity`, which compacts desktop layouts and erodes
///   the tap-target baseline there.
/// - **Visible focus** — text inputs get a `focusOutlineWidth` primary
///   border. The six button types below get a `primary` ring of that width
///   on keyboard focus only (#644), [BgeButtonFocusRing]:
///   [BgeTokens.focusRingGap] outside the shape on filled, tonal and icon
///   buttons, and inside the edge on text, outlined and elevated buttons,
///   which Flutter clips to their shape. The theme can't reach the rest, so
///   `ui` rings them: a list row sits in `BgeRowFocusRing`, ringed inside the
///   row's box with `radiusMd` corners (#758), and an extended floating
///   action button is a `BgeExtendedFab`, ringed inside its edge (#760).
///   Every ring hides after a mouse press until the next key press
///   ([BgePointerPressed]). A segmented button's segment can't take a
///   ring from the theme, so it shows focus by a fill 3:1 from rest, its
///   label changing with it ([BgeSegmentFocus], #759). A chip's ring is its
///   side, which the theme sets ([BgeChipFocus], #761).
/// - **Two-family typography** — the bundled display face on
///   display/headline/title, the platform face on body/label. See
///   [BgeTypography] for why the split falls there.
/// - **Legible text selection** — an authored `textSelectionTheme`. Material's
///   default tint drops selected text below the floor in all four schemes:
///   under 3:1 in light and dark, and under the 4.5:1 the high-contrast pair
///   is held to. See [BgeSelection] for both floors and what they exclude.
/// - **Dialogs at the reading measure** — capped at
///   [BgeTokens.contentMaxWidth], because a dialog is a title, a sentence or
///   two and its buttons: prose. In the theme so that no dialog has to
///   remember it. Left unset, a dialog may grow to the window minus 40dp
///   insets, up to 2480dp on a 2560 monitor. The one Flutter dialog the cap
///   is wrong for is `showDateRangePicker` in its calendar form, which is
///   built to fill the window; the style guide says how it lifts the cap.
/// - **Field messages that wrap** — a field's helper and error take up to
///   six lines rather than Flutter's one ellipsized line, which cut even
///   short messages at 2.0 text on a narrow phone (#499).
/// - **Dimensional tokens** — [BgeTokens.standard] and [BgeStatusColors] are
///   installed as `ThemeExtension`s on every theme.
/// - **Line colors** — [BgeLineColors], the separator and the row outline,
///   derived from each theme's own scheme and installed on every theme
///   (#659).
/// - **No tint on a scrolled-under app bar** — an authored `appBarTheme`
///   with a transparent `surfaceTintColor`. Material's default tint took
///   `primary` text on the bar below 4.5:1 in light (#802).
/// - **List rows line up with their title** — `ListTileTitleAlignment
///   .titleHeight`, so a tall row's icon, switch or chevron sits beside its
///   title rather than centred (#647). Rows that lead with a thumbnail set
///   their own alignment through `BgeThumbnail.titleAlignmentOf`.
///
/// The high-contrast factories are wired by the shell to
/// `MaterialApp.highContrastTheme` / `highContrastDarkTheme`, so the OS
/// "increase contrast" setting selects them automatically.
abstract final class BgeTheme {
  /// The default light theme.
  static ThemeData light() => storm.light;

  /// The default dark theme.
  static ThemeData dark() => storm.dark;

  /// The high-contrast light theme, wired to `MaterialApp.highContrastTheme`.
  static ThemeData highContrastLight() => storm.highContrastLight;

  /// The high-contrast dark theme, wired to
  /// `MaterialApp.highContrastDarkTheme`.
  static ThemeData highContrastDark() => storm.highContrastDark;

  /// The themes for the default palette.
  ///
  /// Built once and cached: the schemes are const and `ThemeData` is
  /// immutable, so the four defaults are shared, stable-identity instances.
  /// The shell resolves these on every `BgeApp` rebuild
  /// (`widget.theme ?? BgeTheme.light()`); a fresh `ThemeData` per build would
  /// hand `MaterialApp` a new theme identity each time and spuriously
  /// repropagate `Theme` to the whole subtree.
  static final BgeThemeSet storm = from(BgePalette.storm);

  /// Builds the four themes for [palette].
  ///
  /// **Not cached.** Callers that rebuild frequently must hold the result
  /// rather than calling this in a `build` method — see [storm] for why theme
  /// identity stability matters. The default palette is already cached there;
  /// this entry point exists for the future customization feature, whose
  /// palette will arrive from persisted state that already has a natural home
  /// to hold the built themes.
  static BgeThemeSet from(BgePalette palette) => BgeThemeSet._(
    light: _build(palette.light, highContrast: false),
    dark: _build(palette.dark, highContrast: false),
    highContrastLight: _build(palette.highContrastLight, highContrast: true),
    highContrastDark: _build(palette.highContrastDark, highContrast: true),
  );

  static ThemeData _build(ColorScheme scheme, {required bool highContrast}) {
    const tokens = BgeTokens.standard;
    final segmentFocus = (
      selected: BgeSegmentFocus.selected(scheme),
      unselected: BgeSegmentFocus.unselected(scheme),
    );
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: BgeTypography.textTheme(),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      inputDecorationTheme: InputDecorationThemeData(
        // Outlined by default, theme-wide. Previously each feature decided
        // this for itself, so household's fields were outlined and
        // server-onboarding's were not — the same control looking like two
        // different controls depending on which screen you reached it from.
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          borderSide: BorderSide(
            color: scheme.primary,
            width: tokens.focusOutlineWidth,
          ),
        ),
        // #499: a field's helper and error wrap. Left unset, each is one
        // ellipsized line, Flutter's default, and at 320dp and 2.0 text even
        // "Type at least 2 characters" was cut short. Capped rather than
        // unlimited: see [_fieldMessageMaxLines].
        helperMaxLines: _fieldMessageMaxLines,
        errorMaxLines: _fieldMessageMaxLines,
      ),
      // #322: authored rather than inherited. Left unset, Material
      // substitutes `primary` at 40% opacity, which drops selected text
      // below the legibility floor in all four schemes — narrowly in light
      // and dark, and clearly in the high-contrast pair, which is held to
      // the AAA large-text bar. See [BgeSelection].
      textSelectionTheme: TextSelectionThemeData(
        selectionColor: BgeSelection.colorFor(scheme),
      ),
      // #207: the reading measure, from the theme rather than at each call
      // site. See the class doc.
      dialogTheme: DialogThemeData(
        constraints: BoxConstraints(
          minWidth: _dialogMinWidth,
          maxWidth: tokens.contentMaxWidth,
        ),
      ),
      // #644: a keyboard focus ring on each of these. Outside the shape where
      // the button doesn't clip; inside the edge on the three that Flutter
      // clips to their shape once a builder is set. See the class doc.
      filledButtonTheme: FilledButtonThemeData(
        style: _buttonStyle(BgeButtonFocusRingPlacement.outside),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: _buttonStyle(BgeButtonFocusRingPlacement.outside),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _buttonStyle(BgeButtonFocusRingPlacement.inside),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _buttonStyle(BgeButtonFocusRingPlacement.inside),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: _buttonStyle(BgeButtonFocusRingPlacement.inside),
      ),
      // #759: a segment builds its style without the buttons' ring builder,
      // and Material's focus overlay stands about 1.2:1 from rest. So a
      // focused segment paints a fill that stands 3:1 as its background, and
      // its label changes with it, since a selected segment's own label
      // can't be read on any fill that does. Both read the same gate in the
      // same build, so they can't come apart. Every other state is
      // Material's, restated: the theme's property replaces the default
      // whole. See [BgeSegmentFocus].
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: _SegmentBackground(scheme, segmentFocus),
          foregroundColor: _SegmentLabel(scheme, segmentFocus),
          overlayColor: _SegmentOverlay(scheme, segmentFocus),
        ),
      ),
      // #644: a focused bar destination is a fill alone, and Flutter's own
      // focus tint stands about 1.3:1 from the bar. The unselected icon is
      // `onSurface`, so it stands 3:1 from that fill. The rail takes both
      // from the shell, which sets its focus fill around the rail alone: see
      // [BgeNavigationFocus].
      navigationBarTheme: NavigationBarThemeData(
        overlayColor: _FocusFill(BgeNavigationFocus.barFill(scheme)),
        iconTheme: _NavigationIcon(
          selected: IconThemeData(color: scheme.onSecondaryContainer),
          unselected: IconThemeData(
            color: BgeNavigationFocus.iconColor(scheme),
          ),
        ),
      ),
      // The rail takes this in place of its default rather than merged with
      // it, so the size the default carries is set here too.
      navigationRailTheme: NavigationRailThemeData(
        unselectedIconTheme: IconThemeData(
          color: BgeNavigationFocus.iconColor(scheme),
          size: 24,
        ),
      ),
      // #802: content scrolled under an app bar raises it to
      // `surfaceContainer`, and Material lays `surfaceTint` (`primary`) over
      // that at 8%. In light that took `primary` text on the bar to 4.39:1.
      // With no tint the bar stays `surfaceContainer`, 4.88:1.
      appBarTheme: const AppBarThemeData(surfaceTintColor: Colors.transparent),
      // #647: with Material's default alignment a tall row's leading and
      // trailing are centred, so beside the subtitle and away from the
      // title. `titleHeight` puts them at the title's first line when the
      // row is tall, and centres them when it is not. Rows that lead with a
      // thumbnail set their own alignment (`BgeThumbnail.titleAlignmentOf`);
      // this governs every other row: icons, switches, chevrons.
      listTileTheme: const ListTileThemeData(
        titleAlignment: ListTileTitleAlignment.titleHeight,
      ),
      extensions: [
        tokens,
        BgeStatusColors.forScheme(scheme),
        BgeLineColors.forScheme(scheme, highContrast: highContrast),
      ],
    );
    // #761: a chip shows focus by a `focusOutlineWidth` ring its side draws,
    // which hides after a mouse press as every ring does. Set after the
    // theme is built, since a selected chip's ring is chosen against the
    // theme's own focus tint. See [BgeChipFocus].
    return theme.copyWith(
      chipTheme: ChipThemeData(
        side: _ChipFocusSide(
          unselected: BgeChipFocus.ringColor(theme, selected: false),
          selected: BgeChipFocus.ringColor(theme, selected: true),
          ringWidth: tokens.focusOutlineWidth,
          atRest: scheme.outlineVariant,
        ),
      ),
    );
  }
}

/// The four [ThemeData]s built from one [BgePalette].
@immutable
class BgeThemeSet {
  const BgeThemeSet._({
    required this.light,
    required this.dark,
    required this.highContrastLight,
    required this.highContrastDark,
  });

  /// Standard-contrast light theme.
  final ThemeData light;

  /// Standard-contrast dark theme.
  final ThemeData dark;

  /// High-contrast light theme.
  final ThemeData highContrastLight;

  /// High-contrast dark theme.
  final ThemeData highContrastDark;
}

/// A [WidgetStateProperty] that is [color] while focused and unset otherwise.
///
/// A class rather than `resolveWith`, so two themes built from one palette
/// compare equal.
@immutable
class _FocusFill implements WidgetStateProperty<Color?> {
  const _FocusFill(this.color);

  final Color color;

  @override
  Color? resolve(Set<WidgetState> states) =>
      states.contains(WidgetState.focused) ? color : null;

  @override
  bool operator ==(Object other) => other is _FocusFill && other.color == color;

  @override
  int get hashCode => color.hashCode;
}

/// A navigation bar's icon colours by state, with the value equality that
/// `resolveWith` lacks, so two themes built from one palette compare equal.
@immutable
class _NavigationIcon implements WidgetStateProperty<IconThemeData?> {
  const _NavigationIcon({required this.selected, required this.unselected});

  final IconThemeData selected;
  final IconThemeData unselected;

  @override
  IconThemeData? resolve(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled)
      ? null
      : states.contains(WidgetState.selected)
      ? selected
      : unselected;

  @override
  bool operator ==(Object other) =>
      other is _NavigationIcon &&
      other.selected == selected &&
      other.unselected == unselected;

  @override
  int get hashCode => Object.hash(selected, unselected);
}

/// [color] at [opacity], as Material's `withOpacity` rounds it, so a state
/// the theme restates resolves to the very colour Material's default does.
Color _materialOpacity(Color color, double opacity) =>
    color.withAlpha((255 * opacity).round());

/// A segment's focus fills and labels, selected and not.
typedef _SegmentFocus = ({
  BgeSegmentFocus selected,
  BgeSegmentFocus unselected,
});

/// A segment's colour for one part by state (#759), with value equality, so
/// two themes built from one palette compare equal.
@immutable
abstract class _SegmentProperty implements WidgetStateProperty<Color?> {
  const _SegmentProperty(this.scheme, this.focus);

  final ColorScheme scheme;
  final _SegmentFocus focus;

  /// Whether a segment in [states] shows keyboard focus.
  ///
  /// `WidgetState.focused` holds whenever the segment has focus, but the
  /// ink well shows focus only while the highlight mode is the keyboard's.
  /// The fill and the label both ask here, in the same build, so a label
  /// never sits on the rest colour without its fill.
  static bool showsFocus(Set<WidgetState> states) =>
      states.contains(WidgetState.focused) &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  /// [focus]'s selected or unselected half, for [states].
  BgeSegmentFocus focusFor(Set<WidgetState> states) =>
      states.contains(WidgetState.selected) ? focus.selected : focus.unselected;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is _SegmentProperty &&
      other.scheme == scheme &&
      other.focus == focus;

  @override
  int get hashCode => Object.hash(runtimeType, scheme, focus);
}

/// A segment's background: Material's, or the focus fill while it shows
/// focus.
class _SegmentBackground extends _SegmentProperty {
  const _SegmentBackground(super.scheme, super.focus);

  @override
  Color? resolve(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) return null;
    if (_SegmentProperty.showsFocus(states)) {
      return focusFor(states).background;
    }
    return states.contains(WidgetState.selected)
        ? scheme.secondaryContainer
        : null;
  }
}

/// A segment's label and icon colour: Material's, or the label solved with
/// the focus fill while it shows focus.
class _SegmentLabel extends _SegmentProperty {
  const _SegmentLabel(super.scheme, super.focus);

  @override
  Color? resolve(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) {
      return _materialOpacity(scheme.onSurface, 0.38);
    }
    if (_SegmentProperty.showsFocus(states)) return focusFor(states).label;
    return states.contains(WidgetState.selected)
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
  }
}

/// A segment's overlay: Material's press and hover tints, and no focus tint,
/// since the background shows focus.
///
/// Focus alone gets Material's tint colour at no strength, not null, which
/// would fall through to the text button's own focus tint. The colour
/// matters though it draws nothing: an ink well creates its focus
/// highlight with every state the segment is in, so focus that arrives
/// under a resting mouse fixes the highlight's strength at the hover's 8%,
/// and then paints it in this colour. In Material's tint, that is one more
/// hover tint, which the fill is solved to carry the label under.
class _SegmentOverlay extends _SegmentProperty {
  const _SegmentOverlay(super.scheme, super.focus);

  @override
  Color? resolve(Set<WidgetState> states) {
    final tint = states.contains(WidgetState.selected)
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    if (states.contains(WidgetState.pressed)) {
      return _materialOpacity(tint, 0.1);
    }
    if (states.contains(WidgetState.hovered)) {
      return BgeSegmentFocus.hoverTint(tint);
    }
    if (states.contains(WidgetState.focused)) return tint.withAlpha(0);
    return null;
  }
}

/// A chip's side (#761): a ring while it shows keyboard focus, and
/// Material's otherwise.
///
/// Every other state resolves to null, and the chip falls back to its own
/// default side, which differs by chip type and variant. With no state at
/// all, it is [atRest], Material's flat chip at rest, spelled out: a theme
/// animation lerps the two themes' sides resolved with no state, and throws
/// where both are null. An elevated chip, which has none in this app, would
/// take that outline at rest too.
///
/// That lerp flattens the side to a plain [BorderSide] for the animation's
/// length, so a chip focused while the theme changes, light to dark, loses
/// its ring until the animation ends.
@immutable
class _ChipFocusSide extends WidgetStateBorderSide {
  const _ChipFocusSide({
    required this.unselected,
    required this.selected,
    required this.ringWidth,
    required this.atRest,
  });

  /// The ring on an unselected chip.
  final Color unselected;

  /// The ring on a selected chip.
  final Color selected;

  /// The ring's width.
  final double ringWidth;

  /// Material's side on a flat chip with no state.
  final Color atRest;

  /// Where the ring sits on the chip's edge: its inset matches the 1px side
  /// Material draws at rest, half the ring inside the edge and half outside
  /// when it is 2 wide.
  ///
  /// A chip pads its content by its side's inset (`ShapeDecoration`'s
  /// padding), so a ring wholly inside the edge would grow the chip as it
  /// takes focus, and move whatever sits beside it.
  double get _strokeAlign => 1 - 2 * const BorderSide().width / ringWidth;

  @override
  BorderSide? resolve(Set<WidgetState> states) {
    if (BgeChipFocus.showsRing(states)) {
      return BorderSide(
        color: states.contains(WidgetState.selected) ? selected : unselected,
        width: ringWidth,
        strokeAlign: _strokeAlign,
      );
    }
    return states.isEmpty ? BorderSide(color: atRest) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is _ChipFocusSide &&
      other.unselected == unselected &&
      other.selected == selected &&
      other.ringWidth == ringWidth &&
      other.atRest == atRest;

  @override
  int get hashCode => Object.hash(unselected, selected, ringWidth, atRest);
}
