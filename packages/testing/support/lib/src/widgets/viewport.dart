import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Sets the test view's render surface to [size], and registers the reset.
///
/// `MediaQueryData.size` is **metadata, not layout constraints** — a widget
/// under `MediaQuery(size: Size(320, 480))` still lays out against the test
/// view's 800x600 default. Every "narrow window" case that sets only that field
/// runs at 800 wide and tests nothing about narrow windows. The size has to go
/// on `tester.view`.
///
/// The teardown is not optional and not the caller's to remember. `tester.view`
/// lives on the singleton binding and `TestWidgetsFlutterBinding.reset()` does
/// **not** restore it, so a suite that forgets the reset leaks a modified view
/// into every later test in that file. Ten call sites hand-rolled this before
/// #213, and one of them had already drifted to a different teardown.
void useViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Sets the render surface to [size], then hosts [child] under the design
/// system's theme at [textScale].
///
/// Use this when the test has no harness of its own. A suite that already
/// builds its own `MaterialApp` (with routes, providers or blocs) should call
/// [useViewSize] instead and add `theme: BgeTheme.light()` to that harness —
/// the theme matters either way, because without it `BgeTokens.of` falls back
/// to [BgeTokens.standard], and a measure assertion written against
/// `BgeTokens.standard` then cannot fail.
///
/// The text scaler is different from the size: an ancestor `MediaQuery` IS
/// effective for it. The framework's own `MediaQuery.fromView` is inserted by
/// `View`, ABOVE the widget under test — `WidgetsApp` inserts none of its own —
/// so this wrapper sits below it and wins. Verified, not assumed.
Widget hostAtSize(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
  double textScale = 1,
}) {
  useViewSize(tester, size);

  return MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
    child: MaterialApp(theme: BgeTheme.light(), home: child),
  );
}
