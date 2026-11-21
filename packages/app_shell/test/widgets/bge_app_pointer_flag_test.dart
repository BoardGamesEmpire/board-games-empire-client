import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart' show BgeFocusRing;
import 'package:ui_tokens/ui_tokens.dart';

import '../support/no_later_recoveries.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    with NoLaterRecoveries
    implements AppBootstrapCubit {}

/// The app root holds the focus lease for as long as it is built: the
/// app-wide pointer flag (#758), so a chip's themed ring (#761), which has
/// no lifecycle of its own, can read a press that came while no ring was
/// built, and the rebuild of the focused chip as the flag changes.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapInitializing(),
    );
  });

  /// Unmounts the app as the test ends, last of its tear-downs, so a test
  /// that fails with the app built can't leave its lease held for the next.
  void unmountAppAfter(WidgetTester tester) =>
      addTearDown(() => tester.pumpWidget(const SizedBox()));

  Future<void> mousePress(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10), kind: PointerDeviceKind.mouse);
    await tester.pump();
  }

  testWidgets('BgeApp holds the pointer flag for its lifetime', (
    tester,
  ) async {
    unmountAppAfter(tester);
    // No lease yet: a press goes unrecorded.
    await tester.pumpWidget(const SizedBox());
    await mousePress(tester);
    expect(BgePointerPressed.value, isFalse, reason: 'before the app');

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    // Not pumpAndSettle: the splash spinner animates while bootstrap waits.
    await tester.pump();
    expect(find.byType(SplashScreen), findsOneWidget);
    // So the flag is the app's to hold: nothing on the splash rings.
    expect(
      find.byWidgetPredicate(
        (w) => w is ButtonStyleButton || w is BgeFocusRing || w is RawChip,
      ),
      findsNothing,
    );

    await mousePress(tester);
    expect(BgePointerPressed.value, isTrue, reason: 'a press in the app');
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(BgePointerPressed.value, isFalse, reason: 'a key press');
    await mousePress(tester);
    expect(BgePointerPressed.value, isTrue, reason: 'another press');

    // Gone, the app lets go: the press is forgotten, and the next unheard.
    await tester.pumpWidget(const SizedBox());
    expect(BgePointerPressed.value, isFalse, reason: 'after the app');
    await mousePress(tester);
    expect(BgePointerPressed.value, isFalse, reason: 'a press after it');
  });

  testWidgets(
    'BgeApp rebuilds a focused chip as the flag changes, so a press hides its '
    'ring and a key press brings it back',
    (tester) async {
      unmountAppAfter(tester);
      await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
      await tester.pump();

      // A chip in the app's own overlay, so it takes the app's theme and
      // nothing but the app holds the flag or rebuilds it.
      const chipKey = Key('chip');
      final node = FocusNode();
      addTearDown(node.dispose);
      final entry = OverlayEntry(
        builder: (_) => Material(
          type: MaterialType.transparency,
          child: Center(
            child: FilterChip(
              key: chipKey,
              focusNode: node,
              label: const Text('Entry'),
              onSelected: (_) {},
            ),
          ),
        ),
      );
      tester.state<OverlayState>(find.byType(Overlay).first).insert(entry);
      addTearDown(
        () => entry
          ..remove()
          ..dispose(),
      );
      await tester.pump();

      final scheme = Theme.of(tester.element(find.byKey(chipKey))).colorScheme;
      BorderSide side() =>
          (tester
                      .widget<Material>(
                        find
                            .descendant(
                              of: find.byKey(chipKey),
                              matching: find.byType(Material),
                            )
                            .first,
                      )
                      .shape!
                  as OutlinedBorder)
              .side;
      final material = BorderSide(color: scheme.outlineVariant);

      node.requestFocus();
      await tester.sendKeyEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(node.hasPrimaryFocus, isTrue);
      expect(side().width, BgeTokens.standard.focusOutlineWidth);
      expect(side().color, scheme.primary, reason: 'the keyboard rings it');

      // A press away from the chip, which keeps focus.
      await mousePress(tester);
      expect(node.hasPrimaryFocus, isTrue);
      expect(side(), material, reason: 'the press');

      await tester.sendKeyEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(side().color, scheme.primary, reason: 'a key press');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
