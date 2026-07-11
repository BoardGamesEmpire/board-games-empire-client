import 'package:flutter/widgets.dart';

/// Reduced-motion convention (#32).
///
/// No app animations exist yet; this helper establishes the convention
/// they must follow when they land: resolve every animation duration
/// through [durationOf] (typically with a `BgeTokens` motion token) so
/// the OS reduce-motion setting (`MediaQuery.disableAnimations`) collapses
/// it to [Duration.zero] — the animation completes instantly instead of
/// playing.
abstract final class BgeMotion {
  /// Whether the OS is asking for animations to be disabled or reduced.
  static bool reduceMotionOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// [standard] normally; [Duration.zero] under OS reduced motion.
  static Duration durationOf(BuildContext context, Duration standard) =>
      reduceMotionOf(context) ? Duration.zero : standard;
}
