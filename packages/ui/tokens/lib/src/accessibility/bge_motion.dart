import 'package:flutter/material.dart' show Easing;
import 'package:flutter/widgets.dart';

/// Motion convention: reduced-motion handling, and the easing set (#32).
///
/// No app animations exist yet. This class establishes the convention they
/// must follow when they land — the same reason `BgeTokens` carries motion
/// durations before anything animates.
///
/// ## Duration
///
/// Resolve every animation duration through [durationOf] (typically with a
/// `BgeTokens` motion token) so the OS reduce-motion setting
/// (`MediaQuery.disableAnimations`) collapses it to [Duration.zero] — the
/// animation completes instantly instead of playing.
///
/// ## Easing
///
/// A duration alone does not describe a motion. The same 300ms reads as
/// mechanical on a linear curve and deliberate on a decelerating one, so a
/// token set that stops at durations leaves the more visible half of the
/// decision to whoever writes the first animation.
///
/// These alias Flutter's Material 3 [Easing] constants rather than
/// re-authoring the cubics — the numbers are specified, and a hand-copied
/// `Cubic(0.05, 0.7, 0.1, 1.0)` is a transcription error waiting to happen.
/// They are named for *what the motion is doing*, because that is the
/// question at a call site.
///
/// Easing is deliberately **not** a `BgeTokens` field: `ThemeExtension`
/// requires `lerp`, and interpolating between two curves is not a meaningful
/// operation. Curves also do not vary by palette or brightness.
abstract final class BgeMotion {
  /// Whether the OS is asking for animations to be disabled or reduced.
  static bool reduceMotionOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// [standard] normally; [Duration.zero] under OS reduced motion.
  static Duration durationOf(BuildContext context, Duration standard) =>
      reduceMotionOf(context) ? Duration.zero : standard;

  /// Something arriving: a sheet opening, a banner appearing, a value
  /// settling. Decelerates into place, which reads as the element coming to
  /// rest rather than stopping dead.
  static const Curve enter = Easing.emphasizedDecelerate;

  /// Something leaving: a dismissal, a sheet closing. Accelerates away —
  /// an exit that decelerates looks reluctant.
  static const Curve exit = Easing.emphasizedAccelerate;

  /// Movement within a screen where both ends are visible — a reorder, an
  /// expand/collapse, a selection sliding between positions.
  static const Curve standard = Easing.standard;

  /// The full emphasized curve, for the one hero transition on a screen.
  /// Using it everywhere is how an interface starts to feel slow.
  ///
  /// Comes from [Curves], not [Easing]: M3's emphasized curve is a two-part
  /// spline rather than a single cubic, so it has no `Easing` member.
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
}
