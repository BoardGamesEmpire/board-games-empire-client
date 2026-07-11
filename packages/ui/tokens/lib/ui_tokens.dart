/// Design tokens and the theme-level accessibility baseline (#32).
///
/// The single source of truth for color, typography scale, spacing,
/// density, and motion — consumed via `Theme.of(context)`. See README for
/// the call-site conventions (no literal colors, no color-only meaning).
library;

export 'src/accessibility/bge_motion.dart';
export 'src/accessibility/bge_text_scale.dart';
export 'src/accessibility/wcag_contrast.dart';
export 'src/bge_color_schemes.dart';
export 'src/bge_theme.dart';
export 'src/bge_tokens.dart';
export 'src/bge_typography.dart';
