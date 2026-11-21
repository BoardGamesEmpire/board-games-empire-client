import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/bge_focus_fill.dart';
import 'package:ui_tokens/src/accessibility/wcag_contrast.dart';

/// The fill a focused `SegmentedButton` segment shows, and the label on it
/// (#759).
///
/// A segment builds its style without the theme's ring builder, so
/// `BgeTheme` shows its keyboard focus as a fill, painted as the segment's
/// background: it stands [ratio] clear of the segment at rest, and the label
/// goes with it, 4.5:1 on the fill, and with Material's [hoverTint] laid
/// over the fill once or twice as well, since a mouse can rest on a segment
/// the keyboard focused, and a focus highlight made under a resting mouse
/// paints one more.
///
/// A selected segment has its own `secondaryContainer`, so its fill is
/// opaque. An unselected one shows the page, a sheet or a dialog, so its
/// fill is one translucent [BgeFocusOverlay] that has to pass over each of
/// [unselectedBackgrounds].
///
/// A selected segment's label can't stay `onSecondaryContainer`: no fill
/// stands 3:1 from `secondaryContainer` and keeps it 4.5:1. So each label is
/// tried in order, Material's first, and the first with a fill that passes
/// wins.
@immutable
final class BgeSegmentFocus {
  const BgeSegmentFocus._(
    this.background,
    this.label, {
    required this.meetsFloors,
  });

  /// A selected segment's, an opaque fill in place of its
  /// `secondaryContainer`.
  factory BgeSegmentFocus.selected(ColorScheme scheme) {
    final (overlay, label) = _solve(
      scheme,
      backgrounds: [scheme.secondaryContainer],
      labels: [
        scheme.onSecondaryContainer,
        scheme.onInverseSurface,
        scheme.onSurface,
      ],
      hover: scheme.onSecondaryContainer,
    );
    return BgeSegmentFocus._(
      Color.alphaBlend(overlay.color, scheme.secondaryContainer),
      label,
      meetsFloors: overlay.meetsFloors,
    );
  }

  /// An unselected segment's, translucent over each of
  /// [unselectedBackgrounds].
  factory BgeSegmentFocus.unselected(ColorScheme scheme) {
    final (overlay, label) = _solve(
      scheme,
      backgrounds: unselectedBackgrounds(scheme),
      labels: [scheme.onSurface, scheme.onInverseSurface],
      hover: scheme.onSurface,
    );
    return BgeSegmentFocus._(
      overlay.color,
      label,
      meetsFloors: overlay.meetsFloors,
    );
  }

  /// What an unselected segment sits on in the app: a page's surface, a
  /// sheet's `surfaceContainerLow` and a dialog's `surfaceContainerHigh`.
  static List<Color> unselectedBackgrounds(ColorScheme scheme) => [
    scheme.surface,
    scheme.surfaceContainerLow,
    scheme.surfaceContainerHigh,
  ];

  /// Material's hover highlight on a segment: [color] at 8%, as Material's
  /// `withOpacity` rounds it.
  static Color hoverTint(Color color) => color.withAlpha((255 * 0.08).round());

  /// How far the fill stands from the segment at rest.
  static const double ratio = BgeFocusFill.ratio;

  /// The first label in [labels] with an overlay that passes; where none
  /// does, Material's label, the first, with its closest overlay.
  static (BgeFocusOverlay, Color) _solve(
    ColorScheme scheme, {
    required List<Color> backgrounds,
    required List<Color> labels,
    required Color hover,
  }) {
    (BgeFocusOverlay, Color)? first;
    for (final label in labels) {
      final overlay = BgeFocusOverlay.solve(
        backgrounds: backgrounds,
        inks: [
          scheme.onSurface,
          scheme.primary,
          scheme.onSurfaceVariant,
          scheme.inverseSurface,
        ],
        carries: {label: Wcag.aaNormalText},
        // A hover, and a hover laid over a focus highlight the ink well
        // fixed at the hover's strength (see `BgeTheme`'s segment overlay).
        tints: [
          hoverTint(hover),
          Color.alphaBlend(hoverTint(hover), hoverTint(hover)),
        ],
      );
      if (overlay.meetsFloors) return (overlay, label);
      first ??= (overlay, label);
    }
    return first!;
  }

  /// What the segment paints as its background while it shows focus.
  final Color background;

  /// The label's colour, and its icon's, while the segment shows focus.
  final Color label;

  /// Whether [background] and [label] meet every floor they were solved
  /// with.
  ///
  /// False where nothing tried does, which a palette test should fail on
  /// rather than ship.
  final bool meetsFloors;

  @override
  bool operator ==(Object other) =>
      other is BgeSegmentFocus &&
      other.background == background &&
      other.label == label &&
      other.meetsFloors == meetsFloors;

  @override
  int get hashCode => Object.hash(background, label, meetsFloors);

  @override
  String toString() =>
      'BgeSegmentFocus($background, label $label, '
      '${meetsFloors ? 'meets' : 'misses'} its floors)';
}
