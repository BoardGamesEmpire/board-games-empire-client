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
  /// A gap of exactly [customExtent] logical pixels, bypassing the scale.
  ///
  /// Prefer the named constructors. A literal here is precisely what the
  /// enforcement test looks for, so reaching for this should feel like a
  /// decision rather than a default.
  const BgeGap.custom(
    double this.customExtent, {
    this.axis = Axis.vertical,
    super.key,
  }) : _step = BgeSpacingStep.custom;

  /// 4dp — the tightest step. Label to its own helper text.
  const BgeGap.xs({this.axis = Axis.vertical, super.key})
    : _step = BgeSpacingStep.xs,
      customExtent = null;

  /// 8dp — the intra-control gap: spinner to label, icon to text.
  const BgeGap.sm({this.axis = Axis.vertical, super.key})
    : _step = BgeSpacingStep.sm,
      customExtent = null;

  /// 16dp — the inter-control rhythm: field to field.
  const BgeGap.md({this.axis = Axis.vertical, super.key})
    : _step = BgeSpacingStep.md,
      customExtent = null;

  /// 24dp — the section break: last field to submit button.
  const BgeGap.lg({this.axis = Axis.vertical, super.key})
    : _step = BgeSpacingStep.lg,
      customExtent = null;

  /// 32dp.
  const BgeGap.xl({this.axis = Axis.vertical, super.key})
    : _step = BgeSpacingStep.xl,
      customExtent = null;

  /// 48dp.
  const BgeGap.xxl({this.axis = Axis.vertical, super.key})
    : _step = BgeSpacingStep.xxl,
      customExtent = null;

  final BgeSpacingStep _step;

  /// The explicit size passed to [BgeGap.custom]; null for scale steps.
  final double? customExtent;

  /// Which axis the gap occupies. Vertical by default: gaps live in [Column]s
  /// far more often than in [Row]s.
  final Axis axis;

  /// The resolved size, from the ambient token set.
  double extentOf(BuildContext context) =>
      customExtent ?? _step.resolve(BgeTokens.of(context));

  @override
  Widget build(BuildContext context) {
    final extent = extentOf(context);
    return switch (axis) {
      // Only the relevant dimension is constrained. Setting both would force
      // the cross-axis extent of the parent — a square gap in a Column widens
      // the Column to the gap's width.
      Axis.vertical => SizedBox(height: extent),
      Axis.horizontal => SizedBox(width: extent),
    };
  }
}

/// A step on the spacing scale, resolved against a [BgeTokens] instance.
///
/// Exists so [BgeGap] can stay `const` while still reading the ambient tokens
/// — it stores which step it is, not what that step currently measures.
enum BgeSpacingStep {
  /// [BgeTokens.spaceXs].
  xs,

  /// [BgeTokens.spaceSm].
  sm,

  /// [BgeTokens.spaceMd].
  md,

  /// [BgeTokens.spaceLg].
  lg,

  /// [BgeTokens.spaceXl].
  xl,

  /// [BgeTokens.spaceXxl].
  xxl,

  /// An explicit size that is not on the scale.
  custom;

  /// This step's size in [tokens].
  double resolve(BgeTokens tokens) => switch (this) {
    BgeSpacingStep.xs => tokens.spaceXs,
    BgeSpacingStep.sm => tokens.spaceSm,
    BgeSpacingStep.md => tokens.spaceMd,
    BgeSpacingStep.lg => tokens.spaceLg,
    BgeSpacingStep.xl => tokens.spaceXl,
    BgeSpacingStep.xxl => tokens.spaceXxl,
    // Never reached: `BgeGap.custom` supplies its own value.
    BgeSpacingStep.custom => tokens.spaceMd,
  };
}
