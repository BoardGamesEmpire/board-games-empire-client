/// The typography *scale* token (#32) — sizes only, never a family.
///
/// Confirmed decision: the app uses the platform's system typeface (zero
/// font assets, zero network fetches — offline/privacy-first), so
/// `BgeTheme` deliberately sets no `fontFamily`/`textTheme` and Flutter's
/// Material 3 defaults supply the geometry. This class is the single
/// documented source of truth for that scale; `bge_theme_test.dart`
/// asserts the resolved theme matches it, so a Flutter upgrade that moved
/// the scale would fail loudly instead of drifting silently.
///
/// All values are logical-pixel font sizes at a 1.0 text scale; OS font
/// scaling multiplies them (clamped by `BgeTextScale`).
abstract final class BgeTypography {
  /// `displayLarge` role size (logical px at 1.0 scale).
  static const double displayLarge = 57;

  /// `displayMedium` role size (logical px at 1.0 scale).
  static const double displayMedium = 45;

  /// `displaySmall` role size (logical px at 1.0 scale).
  static const double displaySmall = 36;

  /// `headlineLarge` role size (logical px at 1.0 scale).
  static const double headlineLarge = 32;

  /// `headlineMedium` role size (logical px at 1.0 scale).
  static const double headlineMedium = 28;

  /// `headlineSmall` role size (logical px at 1.0 scale).
  static const double headlineSmall = 24;

  /// `titleLarge` role size (logical px at 1.0 scale).
  static const double titleLarge = 22;

  /// `titleMedium` role size (logical px at 1.0 scale).
  static const double titleMedium = 16;

  /// `titleSmall` role size (logical px at 1.0 scale).
  static const double titleSmall = 14;

  /// `bodyLarge` role size (logical px at 1.0 scale).
  static const double bodyLarge = 16;

  /// `bodyMedium` role size (logical px at 1.0 scale).
  static const double bodyMedium = 14;

  /// `bodySmall` role size (logical px at 1.0 scale).
  static const double bodySmall = 12;

  /// `labelLarge` role size (logical px at 1.0 scale).
  static const double labelLarge = 14;

  /// `labelMedium` role size (logical px at 1.0 scale).
  static const double labelMedium = 12;

  /// `labelSmall` role size (logical px at 1.0 scale).
  static const double labelSmall = 11;
}
