import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _fabKey = Key('fab');

/// An extended floating action button that rings itself on keyboard focus,
/// inside its own edge (#760): its focus overlay alone stands 1.17:1 from its
/// rest.
void main() {
  final boundary = GlobalKey();
  const tokens = BgeTokens.standard;

  final themes = {
    'light': BgeTheme.light,
    'dark': BgeTheme.dark,
    'highContrastLight': BgeTheme.highContrastLight,
    'highContrastDark': BgeTheme.highContrastDark,
  };

  /// [fab] at the top left of a 390 by 844 window, in [theme], else the light
  /// theme, with a button after it to which focus can go.
  Future<void> host(
    WidgetTester tester,
    Widget fab, {
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    fab,
                    TextButton(onPressed: () {}, child: const Text('After')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BgeExtendedFab fab({
    VoidCallback? onPressed,
    FocusNode? focusNode,
    bool enabled = true,
  }) => BgeExtendedFab(
    key: _fabKey,
    icon: const Icon(Icons.add),
    label: 'Create',
    onPressed: enabled ? (onPressed ?? () {}) : null,
    focusNode: focusNode,
  );

  Future<void> tab(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }

  Finder button() => find.descendant(
    of: find.byKey(_fabKey),
    matching: find.byType(FloatingActionButton),
  );

  /// Whether [c] is within a little of [target].
  bool near(Color c, Color target) =>
      (c.r - target.r).abs() < 0.05 &&
      (c.g - target.g).abs() < 0.05 &&
      (c.b - target.b).abs() < 0.05;

  group('ringed on keyboard focus, 3:1 against its fill', () {
    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets(name, (tester) async {
        final theme = build();
        await host(tester, fab(), theme: theme);
        final scheme = theme.colorScheme;
        final ringColour = BgeExtendedFab.ringColorOf(scheme);
        final rect = tester.getRect(button());
        final atRest = await capturePixels(tester, boundary);

        await tab(tester);
        await tester.pumpAndSettle();
        expect(
          Focus.of(tester.element(find.text('Create'))).hasPrimaryFocus,
          isTrue,
        );
        final focused = await capturePixels(tester, boundary);

        // The ring's band is the outermost `focusOutlineWidth` of the button.
        // Sample its middle on each side, away from the corners, where the
        // curve smooths the colour. An edge can fall between pixels, and the
        // middle of a 2dp band is a whole pixel in from it.
        final width = tokens.focusOutlineWidth;
        final inset = width / 2;
        final midY = rect.center.dy;
        final band = <Offset>[
          Offset(rect.left + inset, midY),
          Offset(rect.right - inset, midY),
          for (
            var x = rect.left + tokens.radiusLg + 2;
            x < rect.right - tokens.radiusLg - 2;
            x += 4
          ) ...[
            Offset(x, rect.top + inset),
            Offset(x, rect.bottom - inset),
          ],
        ];
        for (final point in band) {
          expect(
            near(focused(point), ringColour),
            isTrue,
            reason: 'the ring colour at $point',
          );
          expect(
            Wcag.contrastRatio(focused(point), scheme.primaryContainer),
            greaterThanOrEqualTo(3.0),
            reason: 'the ring against the FAB fill at $point',
          );
        }
        // ...and it was not there at rest: the band at rest is the fill.
        for (final point in band) {
          expect(
            near(atRest(point), ringColour),
            isFalse,
            reason: 'no ring at rest at $point',
          );
        }
        // The fill the ring is solved against is what the button rests on.
        expect(
          near(
            atRest(Offset(rect.left + width + 3.5, midY)),
            scheme.primaryContainer,
          ),
          isTrue,
          reason: 'the resting fill is primaryContainer',
        );
        // Nothing outside the button's edge is drawn in the ring's colour.
        final outside = rect.inflate(tokens.focusRingGap + width);
        final out = pixelCentres(outside).where(
          (p) => !rect.contains(p) && near(focused(p), ringColour),
        );
        expect(out, isEmpty, reason: 'the ring sits inside the edge');
      });
    }
  });

  group('ringColorOf takes primary where it holds 3:1 on primaryContainer, '
      'else onPrimaryContainer', () {
    for (final MapEntry(key: name, value: build) in themes.entries) {
      test(name, () {
        final scheme = build().colorScheme;
        final holds =
            Wcag.contrastRatio(scheme.primary, scheme.primaryContainer) >= 3;
        expect(
          BgeExtendedFab.ringColorOf(scheme),
          holds ? scheme.primary : scheme.onPrimaryContainer,
        );
      });
    }

    test('a scheme where primary is too close takes the foreground', () {
      const scheme = ColorScheme.light(
        primary: Color(0xFF6750A4),
        primaryContainer: Color(0xFF7B63B8),
        onPrimaryContainer: Color(0xFFFFFFFF),
      );
      expect(BgeExtendedFab.ringColorOf(scheme), scheme.onPrimaryContainer);
    });

    test('a scheme where primary stands apart takes primary', () {
      const scheme = ColorScheme.light(
        primary: Color(0xFF000000),
        primaryContainer: Color(0xFFFFFFFF),
        onPrimaryContainer: Color(0xFF808080),
      );
      expect(BgeExtendedFab.ringColorOf(scheme), scheme.primary);
    });
  });

  group('rests on primaryContainer, which the ring is solved against', () {
    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets(name, (tester) async {
        final theme = build();
        await host(tester, fab(), theme: theme);
        final rect = tester.getRect(button());

        // Well inside the edge and clear of the icon and the label.
        final fill = (await capturePixels(tester, boundary))(
          Offset(rect.left + 6, rect.center.dy),
        );

        expect(fill, theme.colorScheme.primaryContainer);
      });
    }
  });

  testWidgets('no ring after a mouse press', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await host(tester, fab(focusNode: node));
    final rect = tester.getRect(button());
    final ringColour = BgeExtendedFab.ringColorOf(BgeTheme.light().colorScheme);
    final edge = Offset(rect.left + 0.5, rect.center.dy);

    await tab(tester);
    await tester.pumpAndSettle();
    expect(node.hasPrimaryFocus, isTrue);
    expect(
      near((await capturePixels(tester, boundary))(edge), ringColour),
      isTrue,
    );

    // A mouse press on empty space, then focus arriving with the hand on the
    // mouse.
    await tester.tapAt(const Offset(300, 700), kind: PointerDeviceKind.mouse);
    await tester.pump();
    node.requestFocus();
    await tester.pumpAndSettle();

    expect(node.hasPrimaryFocus, isTrue);
    expect(
      near((await capturePixels(tester, boundary))(edge), ringColour),
      isFalse,
    );
  });

  testWidgets("the given focus node is the button's", (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await host(tester, fab(focusNode: node));

    node.requestFocus();
    await tester.pumpAndSettle();

    expect(node.hasPrimaryFocus, isTrue);
    expect(
      tester.widget<FloatingActionButton>(button()).focusNode,
      same(node),
    );
  });

  testWidgets('the label is a BgeFabLabel', (tester) async {
    await host(tester, fab());

    expect(
      find.descendant(
        of: find.byKey(_fabKey),
        matching: find.byType(BgeFabLabel),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<BgeFabLabel>(find.byType(BgeFabLabel)).text,
      'Create',
    );
  });

  testWidgets('it is one focus stop, and the ring wrapper is none', (
    tester,
  ) async {
    await host(tester, fab());

    await tab(tester);
    expect(
      Focus.of(tester.element(find.text('Create'))).hasPrimaryFocus,
      isTrue,
    );
    await tab(tester);
    expect(
      Focus.of(tester.element(find.text('After'))).hasPrimaryFocus,
      isTrue,
    );
  });

  testWidgets('a null onPressed is no focus stop', (tester) async {
    await host(tester, fab(enabled: false));

    await tab(tester);

    expect(
      Focus.of(tester.element(find.text('After'))).hasPrimaryFocus,
      isTrue,
      reason: 'focus skips a button that can do nothing',
    );
    expect(
      Focus.of(tester.element(find.text('Create'))).hasFocus,
      isFalse,
    );
  });

  testWidgets('the ring wrapper adds no semantics: one button, with its label '
      'and tap action', (tester) async {
    final semantics = tester.ensureSemantics();
    await host(tester, fab());

    // The node the label's words sit in, which is the button's own.
    final node = tester.getSemantics(find.text('Create'));
    expect(node.id, tester.getSemantics(button()).id);
    final data = node.getSemanticsData();
    expect(data.label, 'Create');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    // The page's first child is the button's merge boundary itself: the ring
    // wrapper puts no node of its own above it. The page's other child is the
    // button after it.
    final page = tester.getSemantics(find.byType(Scaffold).first);
    final children = <SemanticsNode>[];
    page.visitChildren((child) {
      children.add(child);
      return true;
    });
    expect(children, hasLength(2));
    expect(children.first.mergeAllDescendantsIntoThisNode, isTrue);
    semantics.dispose();
  });
}
