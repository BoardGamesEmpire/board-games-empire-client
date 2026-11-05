/// Widget-test helpers that cannot live in any one package's `test/` tree:
/// the render-surface sizing every screen suite needs (#213), the
/// `scrollChildCount` semantics walk (#257), the scroll-viewport geometry
/// the reveal assertions are written against (#354), and the display
/// typeface a title's fit is measured in (#710).
///
/// Needs `flutter_test`, which is why it is a separate library from
/// `network.dart` (#354 D1).
library;

export 'src/widgets/fonts.dart';
export 'src/widgets/scroll_geometry.dart';
export 'src/widgets/semantics.dart';
export 'src/widgets/viewport.dart';
