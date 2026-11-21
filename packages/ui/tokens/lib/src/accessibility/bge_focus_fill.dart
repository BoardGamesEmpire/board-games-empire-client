import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart' show Color;

import 'package:ui_tokens/src/accessibility/wcag_contrast.dart';

/// A focus fill chosen with the colours that sit on it (#758, #909).
///
/// Where the theme can only set colours, a control shows keyboard focus as a
/// fill. The fill has to stand clear of the control at rest, and whatever
/// sits on it, a label or an icon, has to stay readable. [BgeFocusFill.solve]
/// chooses one colour that does both, and says when no colour it tries does.
@immutable
final class BgeFocusFill {
  const BgeFocusFill._(this.color, {required this.meetsFloors});

  /// The weakest fill that stands [ratio] from [background] and from each
  /// of [standsFrom], and on which each colour [carries] names stands its
  /// floor.
  ///
  /// Each of [inks] is tried in order, laid over [background] at 1/20
  /// strength, then 2/20, up to full, and the first step that passes wins.
  /// Where none passes, the result is the step whose worst constraint comes
  /// nearest its floor, rather than full strength, where a colour it carries
  /// can sit on a fill of itself, and [meetsFloors] is false. With no
  /// [inks], it is [background], which meets nothing.
  factory BgeFocusFill.solve({
    required Color background,
    required List<Color> inks,
    List<Color> standsFrom = const [],
    Map<Color, double> carries = const {},
  }) {
    final found = _search(inks, (overlay) {
      final fill = Color.alphaBlend(overlay, background);
      return [
        (Wcag.contrastRatio(fill, background), ratio),
        for (final other in standsFrom)
          (Wcag.contrastRatio(fill, other), ratio),
        for (final MapEntry(key: colour, value: floor) in carries.entries)
          (Wcag.contrastRatio(colour, fill), floor),
      ];
    });
    return found == null
        ? BgeFocusFill._(background, meetsFloors: false)
        : BgeFocusFill._(
            Color.alphaBlend(found.overlay, background),
            meetsFloors: found.meetsFloors,
          );
  }

  /// How far a fill stands from what it is measured against: 3:1 with a
  /// margin for a blend that lands between two steps.
  static const double ratio = 3.2;

  /// The fill, opaque.
  final Color color;

  /// Whether [color] meets every floor it was solved with.
  ///
  /// False where none of the steps tried does. [color] is then the closest
  /// one, which a palette test should fail on rather than ship.
  final bool meetsFloors;

  @override
  bool operator ==(Object other) =>
      other is BgeFocusFill &&
      other.color == color &&
      other.meetsFloors == meetsFloors;

  @override
  int get hashCode => Object.hash(color, meetsFloors);

  @override
  String toString() =>
      'BgeFocusFill($color, ${meetsFloors ? 'meets' : 'misses'} its floors)';
}

/// A translucent focus overlay, laid over whatever is behind a control, and
/// chosen the way [BgeFocusFill.solve] chooses a fill (#759).
///
/// For a control that shows focus by painting a colour of its own over more
/// than one background, as a segment does over a page, a sheet or a dialog.
@immutable
final class BgeFocusOverlay {
  const BgeFocusOverlay._(this.color, {required this.meetsFloors});

  /// The weakest overlay that, laid over each of [backgrounds], stands
  /// [BgeFocusFill.ratio] from it, and on which each colour [carries] names
  /// stands its floor: on the fill, and with each of [tints] laid over the
  /// fill too, as a hover highlight is laid over a focus fill.
  ///
  /// [inks] and their steps are tried as [BgeFocusFill.solve] tries them,
  /// and the fallback where none passes is the same. [inks] must not be
  /// empty: there is no overlay to give without one. Nor must
  /// [backgrounds]: with none, nothing is measured, and the faintest step
  /// of the first ink would pass.
  factory BgeFocusOverlay.solve({
    required List<Color> backgrounds,
    required List<Color> inks,
    Map<Color, double> carries = const {},
    List<Color> tints = const [],
  }) {
    if (backgrounds.isEmpty) {
      throw ArgumentError.value(backgrounds, 'backgrounds', 'is empty');
    }
    final found = _search(inks, (overlay) {
      final measured = <(double, double)>[];
      for (final background in backgrounds) {
        final fill = Color.alphaBlend(overlay, background);
        measured.add((
          Wcag.contrastRatio(fill, background),
          BgeFocusFill.ratio,
        ));
        for (final under in [
          fill,
          for (final tint in tints) Color.alphaBlend(tint, fill),
        ]) {
          for (final MapEntry(key: colour, value: floor) in carries.entries) {
            measured.add((Wcag.contrastRatio(colour, under), floor));
          }
        }
      }
      return measured;
    });
    if (found == null) throw ArgumentError.value(inks, 'inks', 'is empty');
    return BgeFocusOverlay._(found.overlay, meetsFloors: found.meetsFloors);
  }

  /// The ink at the strength chosen, translucent.
  final Color color;

  /// Whether [color] meets every floor it was solved with, over every
  /// background.
  final bool meetsFloors;

  @override
  bool operator ==(Object other) =>
      other is BgeFocusOverlay &&
      other.color == color &&
      other.meetsFloors == meetsFloors;

  @override
  int get hashCode => Object.hash(color, meetsFloors);

  @override
  String toString() =>
      'BgeFocusOverlay($color, ${meetsFloors ? 'meets' : 'misses'} its '
      'floors)';
}

/// How many steps an ink's strength climbs in, the last one full.
const _steps = 20;

/// The one search behind [BgeFocusFill.solve] and [BgeFocusOverlay.solve]
/// (#758): each of [inks] in order, at 1/20 strength, then 2/20, up to full.
///
/// [measure] gives each constraint's achieved ratio and its floor for an
/// overlay. The first overlay that meets every floor wins. Where none does,
/// the one whose worst constraint comes nearest its floor, with
/// `meetsFloors` false. Null with no [inks].
({Color overlay, bool meetsFloors})? _search(
  List<Color> inks,
  List<(double, double)> Function(Color overlay) measure,
) {
  ({Color overlay, bool meetsFloors})? best;
  var bestShare = double.negativeInfinity;
  for (final ink in inks) {
    // Counted in whole steps: a sum of 0.05s overshoots 1 on the last.
    for (var step = 1; step <= _steps; step++) {
      final overlay = ink.withValues(alpha: step / _steps);
      final measured = measure(overlay);
      if (measured.every((m) => m.$1 >= m.$2)) {
        return (overlay: overlay, meetsFloors: true);
      }
      // The worst constraint, as a share of its floor.
      final share = measured
          .map((m) => m.$1 / m.$2)
          .reduce((a, b) => a < b ? a : b);
      if (share > bestShare) {
        bestShare = share;
        best = (overlay: overlay, meetsFloors: false);
      }
    }
  }
  return best;
}
