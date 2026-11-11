import 'package:bge_test_support/src/widgets/viewport.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The design system's theme on a pointer platform, macOS unless [platform]
/// says otherwise (#338).
///
/// The selection region is gated on `Theme.of(context).platform`
/// ([BgeSelection.isEnabledOn]), and under flutter_test a theme that does
/// not set one reports android, a touch platform. A suite with its own
/// `MaterialApp` passes this as its `theme` to get the region at all —
/// through the theme rather than `debugDefaultTargetPlatformOverride`,
/// which is global and would move `WidgetsApp`'s shortcuts too (see
/// [sendCopyShortcut]).
ThemeData pointerPlatformTheme({
  TargetPlatform platform = TargetPlatform.macOS,
}) => BgeTheme.light().copyWith(platform: platform);

/// A `MaterialApp.builder` that installs [BgeSelectionRegion] where `BgeApp`
/// does: above the Navigator, around every route (#338).
///
/// For a suite with a harness of its own; pair it with
/// [pointerPlatformTheme], since off a pointer platform the region renders
/// its child and nothing else. A builder rather than a wrapper for `home:`:
/// below the Navigator, the Navigator's Overlay would be the screen's root
/// overlay, where in the app the region's own is.
Widget underSelectionRegion(BuildContext context, Widget? child) =>
    BgeSelectionRegion(child: child!);

/// [hostAtSize] on macOS with [underSelectionRegion] as its builder: a
/// screen as a desktop user meets it, under the app's own selection region
/// (#338).
///
/// The real [BgeSelectionRegion], not a `SelectionArea` restated here,
/// because its wrapping order is what the app depends on and a copy would
/// test itself. Sized to a desktop window by default rather than
/// [hostAtSize]'s phone.
///
/// The region mounts on the first frame here. `BgeApp` holds it back one
/// frame, but that is a web load-crash fix for the app's own first frame,
/// and nothing a screen under the region sees once it is up.
Widget hostUnderSelectionRegion(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1280, 800),
  double textScale = 1,
}) => hostAtSize(
  tester,
  child,
  size: size,
  textScale: textScale,
  platform: TargetPlatform.macOS,
  builder: underSelectionRegion,
);

/// Records the text of every `Clipboard.setData` call until the test ends,
/// and returns the live list (#338).
///
/// What a copy lifted is visible only on the platform channel, so this
/// mocks `SystemChannels.platform`, answering every call on it with null.
/// That replaces any mock the suite put on the channel, and does not give
/// it back: the teardown, registered with `addTearDown` so nothing leaks
/// into the next test, removes the channel's mock rather than restoring an
/// earlier one. Read the list after [sendCopyShortcut].
List<String> captureClipboardCopies() {
  final copies = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copies.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copies;
}

/// Presses Control+C, then pumps (#338).
///
/// Control, not Meta, even under a macOS theme, and deliberately:
/// `WidgetsApp`'s default shortcuts are built from `defaultTargetPlatform`,
/// which flutter_test pins to android, whereas the region is gated on
/// `Theme.platform`. The two are independent by design, and this is where
/// that shows.
Future<void> sendCopyShortcut(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Drags a mouse pointer from [from] to [to] in [steps] even moves, pumping
/// after the press, each move and the release (#338).
///
/// A mouse, because that is what a desktop user selects with, and the
/// region's recognizers dispatch on the pointer kind; `tester.drag` and
/// `dragFrom` default to touch.
///
/// In steps, because a real mouse reports a run of small moves, and under
/// the region the difference shows. A scroller there has to beat the
/// region's own drag recognizer in the gesture arena, and the move that
/// decides it is spent starting the scroller's drag, so a drag that jumps
/// in one move scrolls nothing. One move is enough to select text, which
/// is why `bge_app_selection_test.dart` gets away with it; a suite that
/// drags a scroller under the region does not.
Future<void> mouseDrag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  int steps = 10,
}) async {
  assert(steps >= 1, 'a drag needs at least one move');
  final drag = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump();
  for (var i = 1; i <= steps; i++) {
    await drag.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump();
  }
  await drag.up();
  await tester.pump();
}
