import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A bare state with the mixin, for a test to press and read.
class _Probe extends StatefulWidget {
  const _Probe({super.key});

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with BgePointerFocus<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Pins the `:focus-visible` bookkeeping that controls taking focus from a
/// tap share (#707, #709). How a control draws it is pinned on the control.
void main() {
  final probe = GlobalKey<_ProbeState>();

  Future<_ProbeState> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        home: _Probe(key: probe),
      ),
    );
    return probe.currentState!;
  }

  testWidgets('a touch, a stylus or a press with no pointer is not noted', (
    tester,
  ) async {
    final state = await show(tester);

    for (final kind in [
      null,
      PointerDeviceKind.touch,
      PointerDeviceKind.stylus,
      PointerDeviceKind.invertedStylus,
    ]) {
      state.notePointerPress(kind);
      await tester.pump();

      expect(state.pointerFocus, isFalse, reason: '$kind');
      expect(state.pointerFocusColor, isNull, reason: '$kind');
    }
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.trackpad]) {
    testWidgets('a $kind press is noted until a key is pressed', (
      tester,
    ) async {
      final state = await show(tester);

      state.notePointerPress(kind);
      await tester.pump();

      expect(state.pointerFocus, isTrue);
      final hidden = state.pointerFocusColor!;
      expect(hidden.a, 0);
      expect(
        hidden.withValues(alpha: 1),
        BgeTheme.light().focusColor.withValues(alpha: 1),
        reason: "the theme's tint, with no strength",
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(state.pointerFocus, isFalse);
      expect(state.pointerFocusColor, isNull);
    });
  }

  testWidgets('a shortcut held with Control, Alt or Meta does not end it', (
    tester,
  ) async {
    final state = await show(tester);
    state.notePointerPress(PointerDeviceKind.mouse);
    await tester.pump();

    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();

      expect(state.pointerFocus, isTrue, reason: '$modifier+C');
    }
  });

  testWidgets('once disposed, a key press reaches it no more', (tester) async {
    final state = await show(tester);
    state.notePointerPress(PointerDeviceKind.mouse);
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    // A handler left behind would set state on a disposed state, which
    // throws.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
