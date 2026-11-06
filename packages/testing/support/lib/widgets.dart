/// Widget-test helpers that cannot live in any one package's `test/` tree:
/// the render-surface sizing every screen suite needs (#213), the
/// `scrollChildCount` semantics walk (#257), the scroll-viewport geometry
/// the reveal assertions are written against (#354), and the display
/// typeface a title's fit is measured in (#710), and the accessibility audit,
/// the scrolling its below-the-fold calls arrange, and the keyboard-traversal
/// helpers every screen suite calls (#50).
///
/// Needs `flutter_test`, which is why it is a separate library from
/// `network.dart` (#354 D1).
library;

export 'src/widgets/accessibility_audit.dart';
export 'src/widgets/audit_scroll.dart';
export 'src/widgets/fonts.dart';
export 'src/widgets/keyboard_traversal.dart';
export 'src/widgets/scroll_geometry.dart';
export 'src/widgets/semantics.dart';
export 'src/widgets/viewport.dart';
