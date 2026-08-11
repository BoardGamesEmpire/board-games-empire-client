import 'package:flutter/widgets.dart';

import 'package:ui_tokens/src/bge_tokens.dart';

/// A spacing gap on the token scale — the tokenized replacement for
/// `SizedBox(height: 16)` (#165).
///
/// ```dart
/// const BgeGap.md()                        // 16dp vertical, inside a Column
/// const BgeGap.sm(axis: Axis.horizontal)   // 8dp horizontal, inside a Row
/// ```
///
/// ## Why this exists rather than just documenting `BgeTokens.of`
///
/// The rule "no literal spacing at call sites" was written in
/// `CONTRIBUTING.md` and the PR checklist, and repo-wide adherence was still
/// zero. A rule whose correct form is *longer to type* than the wrong one
/// loses, every time, to whoever is trying to finish a screen. This makes the
/// correct form the short one:
///
/// ```dart
/// SizedBox(height: BgeTokens.of(context).spaceMd)   // 46 characters, not const
/// const BgeGap.md()                                 // 17, and const
/// ```
///
/// ## Why the axis is explicit
///
/// A gap could infer its direction by walking up to the enclosing [Flex], and
/// some packages do. This does not: the lookup is fragile (`Column` and `Row`
/// are distinct types, so an exact-type ancestor search misses one), it costs
/// a tree walk per gap, and it fails silently — producing a gap in the wrong
/// axis rather than an error — when a widget lands somewhere unexpected. An
/// [Axis] argument that defaults to the common case is duller and always right.
///
/// Sizes come from [BgeTokens.standard] rather than from context so the widget
/// stays `const`-constructible, which matters when gaps appear a dozen times
/// per screen. The spacing scale is theme-invariant by design (see
/// [BgeTokens]) — a palette varies colors, never the rhythm — so there is
/// nothing context-dependent to look up.
class BgeGap extends StatelessWidget {
  /// A gap of exactly [extent] logical pixels.
  ///
  /// Prefer the named constructors. A literal here is precisely what the
  /// enforcement test looks for, so reaching for this should feel like a
  /// decision rather than a default.
  const BgeGap.custom(this.extent, {this.axis = Axis.vertical, super.key});

  /// 4dp — the tightest step. Label to its own helper text.
  const BgeGap.xs({this.axis = Axis.vertical, super.key})
    : extent = BgeTokens.spaceXsValue;

  /// 8dp — the intra-control gap: spinner to label, icon to text.
  const BgeGap.sm({this.axis = Axis.vertical, super.key})
    : extent = BgeTokens.spaceSmValue;

  /// 16dp — the inter-control rhythm: field to field.
  const BgeGap.md({this.axis = Axis.vertical, super.key})
    : extent = BgeTokens.spaceMdValue;

  /// 24dp — the section break: last field to submit button.
  const BgeGap.lg({this.axis = Axis.vertical, super.key})
    : extent = BgeTokens.spaceLgValue;

  /// 32dp.
  const BgeGap.xl({this.axis = Axis.vertical, super.key})
    : extent = BgeTokens.spaceXlValue;

  /// 48dp.
  const BgeGap.xxl({this.axis = Axis.vertical, super.key})
    : extent = BgeTokens.spaceXxlValue;

  /// The gap size in logical pixels.
  final double extent;

  /// Which axis the gap occupies. Vertical by default: gaps live in [Column]s
  /// far more often than in [Row]s.
  final Axis axis;

  @override
  Widget build(BuildContext context) => switch (axis) {
    // Only the relevant dimension is constrained. Setting both would force
    // the cross-axis extent of the parent — a square gap in a Column widens
    // the Column to the gap's width.
    Axis.vertical => SizedBox(height: extent),
    Axis.horizontal => SizedBox(width: extent),
  };
}
