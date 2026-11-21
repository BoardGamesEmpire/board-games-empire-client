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
    BgeFocusFill? best;
    var bestShare = double.negativeInfinity;
    for (final ink in inks) {
      // Counted in whole steps: a sum of 0.05s overshoots 1 on the last.
      for (var step = 1; step <= _steps; step++) {
        final fill = Color.alphaBlend(
          ink.withValues(alpha: step / _steps),
          background,
        );
        // Each constraint's achieved ratio against its floor.
        final measured = [
          (Wcag.contrastRatio(fill, background), ratio),
          for (final other in standsFrom)
            (Wcag.contrastRatio(fill, other), ratio),
          for (final MapEntry(key: colour, value: floor) in carries.entries)
            (Wcag.contrastRatio(colour, fill), floor),
        ];
        if (measured.every((m) => m.$1 >= m.$2)) {
          return BgeFocusFill._(fill, meetsFloors: true);
        }
        // The worst constraint, as a share of its floor.
        final share = measured
            .map((m) => m.$1 / m.$2)
            .reduce((a, b) => a < b ? a : b);
        if (share > bestShare) {
          bestShare = share;
          best = BgeFocusFill._(fill, meetsFloors: false);
        }
      }
    }
    return best ?? BgeFocusFill._(background, meetsFloors: false);
  }

  /// How far a fill stands from what it is measured against: 3:1 with a
  /// margin for a blend that lands between two steps.
  static const double ratio = 3.2;

  /// How many steps an ink's strength climbs in, the last one full.
  static const _steps = 20;

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
