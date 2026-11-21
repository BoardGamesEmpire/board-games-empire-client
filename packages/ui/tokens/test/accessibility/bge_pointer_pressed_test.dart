import 'package:flutter/gestures.dart' show GestureBinding, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The app-wide flag every focus ring reads: a mouse's press hides them all
/// until the next key press, as a browser's `:focus-visible` does (#758).
void main() {
  const empty = Offset(200, 200);

  /// Attaches as a ring does, detaching when the test ends.
  void attach() {
    BgePointerPressed.attach();
    addTearDown(BgePointerPressed.detach);
  }

  Future<void> mousePress(WidgetTester tester) async {
    await tester.tapAt(empty, kind: PointerDeviceKind.mouse);
    await tester.pump();
  }

  testWidgets('a mouse press sets it and a plain key press clears it', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    attach();
    var changes = 0;
    void count() => changes++;
    BgePointerPressed.listenable.addListener(count);
    addTearDown(() => BgePointerPressed.listenable.removeListener(count));
    expect(BgePointerPressed.value, isFalse);

    await mousePress(tester);
    expect(BgePointerPressed.value, isTrue);
    expect(BgePointerPressed.listenable.value, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(BgePointerPressed.value, isFalse);
    expect(changes, 2, reason: 'a ring hears both');
  });

  testWidgets('a key press with Meta held leaves it set', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    attach();
    await mousePress(tester);

    // A shortcut isn't navigation, whichever of the three holds it.
    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(modifier);
      expect(BgePointerPressed.value, isTrue, reason: modifier.debugName);
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(BgePointerPressed.value, isFalse);
  });

  testWidgets('a held key repeating clears it', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    attach();
    // Tab goes down, and stays down through a click.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    await mousePress(tester);
    expect(BgePointerPressed.value, isTrue);

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
    expect(BgePointerPressed.value, isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
  });

  testWidgets('a touch sets nothing', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    attach();

    await tester.tapAt(empty);
    await tester.pump();
    expect(BgePointerPressed.value, isFalse, reason: 'a touch');

    await tester.tapAt(empty, kind: PointerDeviceKind.stylus);
    await tester.pump();
    expect(BgePointerPressed.value, isFalse, reason: 'a stylus');

    await tester.tapAt(empty, kind: PointerDeviceKind.invertedStylus);
    await tester.pump();
    expect(BgePointerPressed.value, isFalse, reason: 'an inverted stylus');
  });

  testWidgets('two attaches and one detach keep it listening; the last '
      'detach resets it', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final routes = GestureBinding.instance.pointerRouter.debugGlobalRouteCount;

    // Detaches whatever this test still holds, so a failing expect leaves
    // no ring counted for the tests after it.
    var held = 0;
    addTearDown(() {
      for (; held > 0; held--) {
        BgePointerPressed.detach();
      }
    });
    void attachOne() {
      BgePointerPressed.attach();
      held++;
    }

    void detachOne() {
      held--;
      BgePointerPressed.detach();
    }

    attachOne();
    attachOne();
    expect(
      GestureBinding.instance.pointerRouter.debugGlobalRouteCount,
      routes + 1,
      reason: 'one route for every ring, not one each',
    );

    detachOne();
    await mousePress(tester);
    expect(BgePointerPressed.value, isTrue, reason: 'one ring is still built');

    detachOne();
    expect(BgePointerPressed.value, isFalse, reason: 'the press is forgotten');
    expect(
      GestureBinding.instance.pointerRouter.debugGlobalRouteCount,
      routes,
    );

    await mousePress(tester);
    expect(BgePointerPressed.value, isFalse, reason: 'no longer listening');
  });
}
