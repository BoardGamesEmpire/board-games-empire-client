import 'package:flutter/widgets.dart';

/// OS text-scaling support with a documented ceiling (#32).
///
/// The app honors the OS font-size setting up to [maxScaleFactor] — 2.0,
/// the WCAG 2.1 SC 1.4.4 target ("text can be resized up to 200 percent
/// without loss of content or functionality"). The clamp protects layouts
/// from unbounded scale factors while guaranteeing the full required
/// range; it is applied once, app-wide, in the shell's `MaterialApp`
/// builder via `MediaQuery.withClampedTextScaling`.
abstract final class BgeTextScale {
  /// Maximum honored text scale factor (WCAG 1.4.4: 200%).
  static const double maxScaleFactor = 2.0;

  /// The ambient [TextScaler], clamped to [maxScaleFactor].
  ///
  /// Rarely needed directly — the shell clamps the ambient `MediaQuery`
  /// for the whole tree — but available for surfaces rendered outside it
  /// (overlays hosted above the app, tests).
  static TextScaler clampedOf(BuildContext context) =>
      MediaQuery.textScalerOf(context).clamp(maxScaleFactor: maxScaleFactor);
}
