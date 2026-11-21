import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart' show GestureBinding, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One button type the theme rings, and where its ring should be.
class _Case {
  const _Case(this.name, this.placement, this.build);

  final String name;
  final BgeButtonFocusRingPlacement placement;
  final Widget Function(Key key) build;

  Key get key => ValueKey(name);
}

final _cases = [
  _Case(
    'FilledButton',
    BgeButtonFocusRingPlacement.outside,
    (key) => FilledButton(key: key, onPressed: () {}, child: const Text('Go')),
  ),
  _Case(
    'FilledButton.tonal',
    BgeButtonFocusRingPlacement.outside,
    (key) =>
        FilledButton.tonal(key: key, onPressed: () {}, child: const Text('Go')),
  ),
  _Case(
    'IconButton',
    BgeButtonFocusRingPlacement.outside,
    (key) =>
        IconButton(key: key, onPressed: () {}, icon: const Icon(Icons.add)),
  ),
  _Case(
    'OutlinedButton',
    BgeButtonFocusRingPlacement.inside,
    (key) =>
        OutlinedButton(key: key, onPressed: () {}, child: const Text('Go')),
  ),
  _Case(
    'TextButton',
    BgeButtonFocusRingPlacement.inside,
    (key) => TextButton(key: key, onPressed: () {}, child: const Text('Go')),
  ),
  // Doesn't clip, unlike `TextButton()`, but takes its theme's placement:
  // one look per button type, whichever constructor built it.
  _Case(
    'TextButton.icon',
    BgeButtonFocusRingPlacement.inside,
    (key) => TextButton.icon(
      key: key,
      onPressed: () {},
      icon: const Icon(Icons.add),
      label: const Text('Go'),
    ),
  ),
  _Case(
    'ElevatedButton',
    BgeButtonFocusRingPlacement.inside,
    (key) =>
        ElevatedButton(key: key, onPressed: () {}, child: const Text('Go')),
  ),
];

/// The keyboard focus ring the theme gives every Material button (#644).
void main() {
  final theme = BgeTheme.light();
  final ring = BgeButtonFocusRing.colorOf(theme.colorScheme);
  const tokens = BgeTokens.standard;
  final boundary = GlobalKey();
  const goKey = Key('go');

  /// [children] in a column at the top left of a 390 by 844 window, in
  /// [themeData], else the light theme.
  Future<void> host(
    WidgetTester tester,
    List<Widget> children, {
    ThemeData? themeData,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: themeData ?? theme,
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
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A point in the window no control covers.
  const empty = Offset(300, 700);

  /// The ring painters under [within], or in the whole tree.
  List<BgeButtonFocusRingPainter> painters(
    WidgetTester tester, [
    Finder? within,
  ]) => tester
      .widgetList<CustomPaint>(
        within == null
            ? find.byType(CustomPaint)
            : find.descendant(of: within, matching: find.byType(CustomPaint)),
      )
      .map((paint) => paint.foregroundPainter)
      .whereType<BgeButtonFocusRingPainter>()
      .toList();

  /// The ring painters that draw a ring now.
  List<BgeButtonFocusRingPainter> shown(WidgetTester tester) =>
      painters(tester).where((p) => p.color != null).toList();

  /// The button's own [Material], whose shape is the button's.
  Finder materialOf(Key key) => find
      .descendant(of: find.byKey(key), matching: find.byType(Material))
      .first;

  // Within a little of the ring's colour: the ring's edge is a curve, so a
  // pixel on it can be a shade off at the tangent.
  final isRingColour = predicate<Color>(
    (c) =>
        (c.r - ring.r).abs() < 0.05 &&
        (c.g - ring.g).abs() < 0.05 &&
        (c.b - ring.b).abs() < 0.05,
    'the ring colour, $ring',
  );

  Future<void> tab(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }

  test('the same shape and placement give the same builder', () {
    // So a style built in a `build` method compares equal from one build to
    // the next, and two themes built from one palette are equal.
    expect(
      BgeButtonFocusRing.builder(
        const StadiumBorder(),
        placement: BgeButtonFocusRingPlacement.outside,
      ),
      same(
        BgeButtonFocusRing.builder(
          const StadiumBorder(),
          placement: BgeButtonFocusRingPlacement.outside,
        ),
      ),
    );
    expect(
      BgeButtonFocusRing.builder(
        const StadiumBorder(),
        placement: BgeButtonFocusRingPlacement.outside,
      ),
      isNot(
        same(
          BgeButtonFocusRing.builder(
            const StadiumBorder(),
            placement: BgeButtonFocusRingPlacement.inside,
          ),
        ),
      ),
    );
  });

  test('a builder with a colour is not kept, so a colour animating frame by '
      'frame leaves nothing behind', () {
    // A banner's ring takes its foreground, and a light/dark switch lerps
    // that colour each frame. Kept, every frame's builder would stay forever.
    const shape = StadiumBorder();
    const placement = BgeButtonFocusRingPlacement.inside;
    final before = BgeButtonFocusRing.debugCachedBuilderCount;

    final first = BgeButtonFocusRing.builder(
      shape,
      placement: placement,
      color: const Color(0xFF00FF00),
    );
    BgeButtonFocusRing.builder(
      shape,
      placement: placement,
      color: const Color(0xFF00FE00),
    );
    final again = BgeButtonFocusRing.builder(
      shape,
      placement: placement,
      color: const Color(0xFF00FF00),
    );

    expect(BgeButtonFocusRing.debugCachedBuilderCount, before);
    expect(again, isNot(same(first)));
  });

  testWidgets("a given colour draws the ring in it, not the scheme's", (
    tester,
  ) async {
    // For a button on a toned container `primary` was never solved
    // against, such as a banner's action.
    const green = Color(0xFF00FF00);
    await host(tester, [
      TextButton(
        key: goKey,
        style: ButtonStyle(
          backgroundBuilder: BgeButtonFocusRing.builder(
            const StadiumBorder(),
            placement: BgeButtonFocusRingPlacement.inside,
            color: green,
          ),
        ),
        onPressed: () {},
        child: const Text('Go'),
      ),
    ]);
    await tab(tester);

    expect(painters(tester, find.byKey(goKey)).single.color, green);
  });

  testWidgets('Tab rings each button type, and the ring can be seen', (
    tester,
  ) async {
    await host(tester, [for (final c in _cases) c.build(c.key)]);

    // Points on each button's left edge, halfway down: on an outside ring, in
    // the gap before it, and on an inside ring.
    Offset onOutsideRing(Rect r) => Offset(
      r.left - tokens.focusRingGap - tokens.focusOutlineWidth / 2,
      r.center.dy,
    );
    Offset inGap(Rect r) =>
        Offset(r.left - tokens.focusRingGap / 2, r.center.dy);
    Offset onInsideRing(Rect r) =>
        Offset(r.left + tokens.focusOutlineWidth / 2, r.center.dy);

    final atRest = await capturePixels(tester, boundary);
    for (final c in _cases) {
      final rect = tester.getRect(materialOf(c.key));
      final where = c.placement == BgeButtonFocusRingPlacement.outside
          ? onOutsideRing(rect)
          : onInsideRing(rect);
      expect(atRest(where), isNot(isRingColour), reason: '${c.name} at rest');
    }

    for (final c in _cases) {
      await tab(tester);

      final focused = FocusManager.instance.primaryFocus!.context!.widget;
      expect(
        find.ancestor(of: find.byWidget(focused), matching: find.byKey(c.key)),
        findsOneWidget,
        reason: 'Tab reaches ${c.name}',
      );
      expect(shown(tester), hasLength(1), reason: 'only ${c.name} is ringed');
      final painter = painters(tester, find.byKey(c.key)).single;
      expect(painter.color, ring, reason: c.name);
      expect(painter.placement, c.placement, reason: c.name);

      final rect = tester.getRect(materialOf(c.key));
      final pixels = await capturePixels(tester, boundary);
      switch (c.placement) {
        case BgeButtonFocusRingPlacement.outside:
          // An outside ring under a clip is cut away whole. The Material
          // clips once a builder is set, unless the constructor said
          // `Clip.none`: this pins that it still does.
          expect(
            tester.widget<Material>(materialOf(c.key)).clipBehavior,
            Clip.none,
            reason: '${c.name} must not clip its outside ring',
          );
          expect(pixels(onOutsideRing(rect)), isRingColour, reason: c.name);
          expect(
            pixels(inGap(rect)),
            isNot(isRingColour),
            reason: '${c.name}: the gap keeps the ring off the button',
          );
        case BgeButtonFocusRingPlacement.inside:
          expect(pixels(onInsideRing(rect)), isRingColour, reason: c.name);
          expect(
            pixels(onOutsideRing(rect)),
            isNot(isRingColour),
            reason: '${c.name}: the stroke is inside the shape',
          );
      }
    }
  });

  testWidgets('no ring on a touch press', (tester) async {
    await host(tester, [
      FilledButton(key: goKey, onPressed: () {}, child: const Text('Go')),
    ]);

    await tester.tap(find.byKey(goKey));
    await tester.pumpAndSettle();

    expect(shown(tester), isEmpty);
  });

  testWidgets(
    'no ring on a mouse click on macOS',
    (tester) async {
      await host(tester, [
        FilledButton(key: goKey, onPressed: () {}, child: const Text('Go')),
      ]);
      // A key puts the highlight mode to the keyboard's, as on a desktop,
      // and a mouse leaves it there: only the focus can keep the ring away.
      await tester.sendKeyEvent(LogicalKeyboardKey.shift);
      await tester.pump();

      await tester.tap(find.byKey(goKey), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      expect(shown(tester), isEmpty);
    },
    // A variant rather than setting `debugDefaultTargetPlatformOverride` in
    // the body: the binding checks it is unset before `addTearDown` runs.
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  group('a mouse press anywhere hides every ring until the next key press, as '
      "a browser's :focus-visible does", () {
    /// Presses [finder] with a mouse, as a desktop user clicks.
    Future<void> click(WidgetTester tester, Finder finder) async {
      await tester.tap(finder, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
    }

    /// A dialog whose one button, "Close", closes it.
    Future<void> showCloseDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Dialog'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );

    /// The ring painter of the button [key] names.
    BgeButtonFocusRingPainter ringOf(WidgetTester tester, Key key) =>
        painters(tester, find.byKey(key)).single;

    testWidgets(
      'focus a mouse-closed dialog hands back to a clicked opener',
      (tester) async {
        await host(tester, [
          Builder(
            builder: (context) => TextButton(
              key: goKey,
              onPressed: () => showCloseDialog(context),
              child: const Text('Open'),
            ),
          ),
        ]);
        // On a desktop the highlight mode is the keyboard's, and a mouse
        // leaves it there.
        await tab(tester);
        final opener = FocusManager.instance.primaryFocus;
        expect(ringOf(tester, goKey).color, ring, reason: 'Tab rings it');

        // The ring goes as the button goes down, while focus is still here.
        final press = await tester.startGesture(
          tester.getCenter(find.byKey(goKey)),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, same(opener));
        expect(ringOf(tester, goKey).color, isNull, reason: 'the press');
        await press.up();
        await tester.pumpAndSettle();
        await click(tester, find.text('Close'));

        expect(find.byType(AlertDialog), findsNothing);
        expect(FocusManager.instance.primaryFocus, same(opener));
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect(ringOf(tester, goKey).color, isNull, reason: 'focus back');

        // A shortcut isn't navigation: Meta+C leaves it hidden.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(ringOf(tester, goKey).color, isNull, reason: 'Meta+C');

        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        await tester.pump();
        expect(ringOf(tester, goKey).color, ring, reason: 'a key press');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      "a menu's kebab, clicked, whose item opens a dialog the mouse closes",
      (tester) async {
        // The flow the live web pass saw on the event detail's date menu
        // (#50): focus comes back to the kebab through the menu and the
        // dialog.
        const kebabKey = Key('kebab');
        await host(tester, [
          Builder(
            builder: (context) => MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => showCloseDialog(context),
                  child: const Text('Edit'),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                key: kebabKey,
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onPressed: controller.isOpen
                    ? controller.close
                    : controller.open,
              ),
            ),
          ),
        ]);
        await tab(tester);
        final kebab = FocusManager.instance.primaryFocus;
        expect(ringOf(tester, kebabKey).color, ring, reason: 'Tab rings it');

        await click(tester, find.byKey(kebabKey));
        await click(tester, find.text('Edit'));
        // The item's onPressed runs after the frame the menu closes in.
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await click(tester, find.text('Close'));

        expect(FocusManager.instance.primaryFocus, same(kebab));
        expect(ringOf(tester, kebabKey).color, isNull, reason: 'focus back');

        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        await tester.pump();
        expect(ringOf(tester, kebabKey).color, ring, reason: 'a key press');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'focus handed back to an opener the mouse never pressed',
      (tester) async {
        // Opened by keyboard, closed by mouse: the user's hand is on the
        // mouse when focus comes back.
        await host(tester, [
          Builder(
            builder: (context) => TextButton(
              key: goKey,
              onPressed: () => showCloseDialog(context),
              child: const Text('Open'),
            ),
          ),
        ]);
        await tab(tester);
        final opener = FocusManager.instance.primaryFocus;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);

        await click(tester, find.text('Close'));

        expect(FocusManager.instance.primaryFocus, same(opener));
        expect(ringOf(tester, goKey).color, isNull, reason: 'focus back');

        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        await tester.pump();
        expect(ringOf(tester, goKey).color, ring, reason: 'a key press');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'a button that autofocuses after a click draws no ring',
      (tester) async {
        // A click opens a confirmation whose action takes focus itself: a
        // new button, which no press of its own has touched.
        const confirmKey = Key('confirm');
        await host(tester, [
          Builder(
            builder: (context) => FilledButton(
              key: goKey,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Delete?'),
                  actions: [
                    TextButton(
                      key: confirmKey,
                      autofocus: true,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ),
              child: const Text('Delete…'),
            ),
          ),
        ]);
        // On a desktop the highlight mode is the keyboard's.
        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        await tester.pump();

        await click(tester, find.byKey(goKey));

        expect(
          Focus.of(
            tester.element(find.text('Delete')),
          ).hasPrimaryFocus,
          isTrue,
        );
        expect(ringOf(tester, confirmKey).color, isNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.shift);
        await tester.pump();
        expect(ringOf(tester, confirmKey).color, ring, reason: 'a key press');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'a held key that repeats after a click brings the ring back',
      (tester) async {
        const otherKey = Key('other');
        await host(tester, [
          FilledButton(key: goKey, onPressed: () {}, child: const Text('Go')),
          FilledButton(
            key: otherKey,
            onPressed: () {},
            child: const Text('Other'),
          ),
        ]);
        // Tab goes down, and stays down through a click.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(ringOf(tester, goKey).color, ring, reason: 'Tab rings it');
        await click(tester, find.byKey(goKey));
        expect(ringOf(tester, goKey).color, isNull, reason: 'the click');

        // Its repeat moves focus on, and the ring with it.
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          Focus.of(tester.element(find.text('Other'))).hasPrimaryFocus,
          isTrue,
        );
        expect(ringOf(tester, otherKey).color, ring, reason: 'the repeat');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.tab);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'holds no pointer route or key handler once no button is built',
      (tester) async {
        final routes =
            GestureBinding.instance.pointerRouter.debugGlobalRouteCount;
        await host(tester, [
          FilledButton(key: goKey, onPressed: () {}, child: const Text('Go')),
          TextButton(onPressed: () {}, child: const Text('Other')),
        ]);
        expect(
          GestureBinding.instance.pointerRouter.debugGlobalRouteCount,
          routes + 1,
          reason: 'one for every ring, not one each',
        );
        await click(tester, find.byKey(goKey));

        await tester.pumpWidget(const SizedBox.shrink());
        expect(
          GestureBinding.instance.pointerRouter.debugGlobalRouteCount,
          routes,
        );

        // Built again, a button starts from the keyboard's side: the press
        // was forgotten with the last ring.
        await host(tester, [
          FilledButton(key: goKey, onPressed: () {}, child: const Text('Go')),
        ]);
        await tab(tester);
        expect(ringOf(tester, goKey).color, ring);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });

  testWidgets('focus restored in touch mode draws no ring', (tester) async {
    // As when a dialog closes on a phone and gives focus back to the button
    // that opened it: no keyboard is involved, so no ring.
    final node = FocusNode();
    addTearDown(node.dispose);
    await host(tester, [
      FilledButton(
        key: goKey,
        focusNode: node,
        onPressed: () {},
        child: const Text('Go'),
      ),
    ]);
    await tester.tapAt(empty);
    await tester.pump();
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);

    node.requestFocus();
    // Settled, not one pump: the focus change lands in a microtask, and the
    // button rebuilds for it in the frame after.
    await tester.pumpAndSettle();

    expect(node.hasPrimaryFocus, isTrue);
    expect(shown(tester), isEmpty);
  });

  testWidgets('the ring follows a highlight-mode change while focused', (
    tester,
  ) async {
    await host(tester, [
      FilledButton(key: goKey, onPressed: () {}, child: const Text('Go')),
    ]);
    await tab(tester);
    final focus = FocusManager.instance.primaryFocus;
    expect(shown(tester), hasLength(1));

    // A touch elsewhere: the button keeps focus, and the ring goes.
    await tester.tapAt(empty);
    await tester.pump();
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(shown(tester), isEmpty);

    // Any key back to the keyboard's mode, with nothing else changing.
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(
      FocusManager.instance.highlightMode,
      FocusHighlightMode.traditional,
    );
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(shown(tester), hasLength(1));
  });

  testWidgets('a button disposed while the ring is suppressed leaves no '
      'listener', (tester) async {
    const otherKey = Key('other');
    await host(tester, [
      FilledButton(key: goKey, onPressed: () {}, child: const Text('Go')),
      FilledButton(key: otherKey, onPressed: () {}, child: const Text('Two')),
    ]);
    await tester.tap(find.byKey(goKey), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(shown(tester), isEmpty, reason: 'the press suppresses the ring');

    // The pressed button goes while the ring is still suppressed.
    await host(tester, [
      FilledButton(key: otherKey, onPressed: () {}, child: const Text('Two')),
    ]);
    expect(find.byKey(goKey), findsNothing);

    await tab(tester);

    expect(painters(tester, find.byKey(otherKey)).single.color, ring);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter and Space keep the ring', (tester) async {
    var pressed = 0;
    await host(tester, [
      FilledButton(
        key: goKey,
        onPressed: () => pressed++,
        child: const Text('Go'),
      ),
    ]);
    await tab(tester);
    expect(shown(tester), hasLength(1), reason: 'Tab rings it');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pressed, 1, reason: 'Enter presses it');
    expect(shown(tester), hasLength(1), reason: 'after Enter');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(pressed, 2, reason: 'Space presses it');
    expect(shown(tester), hasLength(1), reason: 'after Space');
  });

  // The navigation shell's bar (#414) shows focus as a fill alone, so the fill
  // must stand apart from rest by 3:1 (#644), and the icon on it from the
  // fill (WCAG 1.4.11). The rail's fill is the shell's; its test is there.
  group("a navigation bar's focused destination differs from rest by 3:1", () {
    final themes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };

    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets(name, (tester) async {
        await host(tester, [
          NavigationBar(
            key: goKey,
            onDestinationSelected: (_) {},
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.search), label: 'Entry'),
            ],
          ),
        ], themeData: build());
        // The second destination: the first is selected, and its indicator
        // would mask the focus fill.
        final icon = tester.getRect(find.byIcon(Icons.search));
        // Round the icon, where the indicator's pill shows the fill.
        final area = icon.inflate(8);
        final atRest = await capturePixels(tester, boundary);

        await tab(tester);
        await tab(tester);
        await tester.pumpAndSettle();
        expect(
          Focus.of(tester.element(find.text('Entry'))).hasPrimaryFocus,
          isTrue,
        );
        final focused = await capturePixels(tester, boundary);

        // Anywhere the focus shows: a fill, a ring, an edge.
        expect(
          strongestContrast(area, atRest, focused),
          greaterThanOrEqualTo(3.0),
          reason: 'the fill',
        );

        // The icon against the fill beside it.
        final fill = focused(Offset(icon.left - 4, icon.center.dy));
        expect(
          strongestContrast(icon, focused, (_) => fill),
          greaterThanOrEqualTo(3.0),
          reason: 'the icon',
        );
      });
    }
  });

  // The selected destination too (#909). The focus fill paints over the
  // indicator, and the selected icon keeps its colour whatever the focus.
  // No fill stands 3:1 from the indicator and carries both icons at 3:1 in
  // any theme, so this stays skipped until the issue settles another way.
  group(
    'a focused selected bar destination differs from rest-selected by 3:1 '
    'over its icon',
    skip: '#909: no fill meets it; see the issue',
    () {
      final themes = {
        'light': BgeTheme.light,
        'dark': BgeTheme.dark,
        'highContrastLight': BgeTheme.highContrastLight,
        'highContrastDark': BgeTheme.highContrastDark,
      };

      for (final MapEntry(key: name, value: build) in themes.entries) {
        testWidgets(name, (tester) async {
          await host(tester, [
            NavigationBar(
              key: goKey,
              onDestinationSelected: (_) {},
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Entry',
                ),
              ],
            ),
          ], themeData: build());
          // The first destination, the selected one, on its indicator.
          final icon = tester.getRect(find.byIcon(Icons.home));
          final area = icon.inflate(8);
          final atRest = await capturePixels(tester, boundary);

          await tab(tester);
          await tester.pumpAndSettle();
          expect(
            Focus.of(tester.element(find.text('Home'))).hasPrimaryFocus,
            isTrue,
          );
          final focused = await capturePixels(tester, boundary);

          // Around the icon only, so the icon can't stand in for the fill.
          expect(
            strongestContrast(area, atRest, focused, skip: icon.contains),
            greaterThanOrEqualTo(3.0),
            reason: 'the fill',
          );

          // The icon against the fill beside it.
          final fill = focused(Offset(icon.left - 4, icon.center.dy));
          expect(
            strongestContrast(icon, focused, (_) => fill),
            greaterThanOrEqualTo(3.0),
            reason: 'the icon',
          );
        });
      }
    },
  );

  // A segmented button builds its segments' style without the theme's
  // builder, so a segment shows keyboard focus as a fill (#759). The fill
  // stands 3:1 from the segment at rest, and the label on it 4.5:1, over
  // every background a segment sits on in the app: a page's surface, a
  // sheet's surfaceContainerLow and a dialog's surfaceContainerHigh (the
  // vote control's quick look is both).
  group("a segmented button's focused segment differs from rest by 3:1, "
      'its label 4.5:1 on the fill (#759)', () {
    final themes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };
    final backgrounds = <String, Color Function(ColorScheme)>{
      'surface': (s) => s.surface,
      'surfaceContainerLow': (s) => s.surfaceContainerLow,
      'surfaceContainerHigh': (s) => s.surfaceContainerHigh,
    };

    for (final MapEntry(key: name, value: build) in themes.entries) {
      for (final MapEntry(key: on, value: background) in backgrounds.entries) {
        for (final selected in [true, false]) {
          final which = selected ? 'selected' : 'unselected';
          testWidgets('$name, $which, on $on', (tester) async {
            final themeData = build();
            await host(tester, [
              ColoredBox(
                color: background(themeData.colorScheme),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('One')),
                      ButtonSegment(value: 1, label: Text('Two')),
                    ],
                    selected: const {0},
                    onSelectionChanged: (_) {},
                  ),
                ),
              ),
            ], themeData: themeData);
            final text = find.text(selected ? 'One' : 'Two');
            final segment = tester.getRect(
              find.ancestor(of: text, matching: find.byType(TextButton)),
            );
            final label = tester.getRect(text);
            // Clear of the label, and of a selected segment's check.
            final fillAt = Offset(label.right + 3, label.center.dy);
            final atRest = await capturePixels(tester, boundary);

            // Selected is the first segment, unselected the second.
            await tab(tester);
            if (!selected) await tab(tester);
            await tester.pumpAndSettle();
            expect(Focus.of(tester.element(text)).hasPrimaryFocus, isTrue);
            final focused = await capturePixels(tester, boundary);

            // Round the label, so the label can't stand in for the fill.
            expect(
              strongestContrast(
                segment,
                atRest,
                focused,
                skip: label.inflate(2).contains,
              ),
              greaterThanOrEqualTo(3.0),
              reason: 'the fill',
            );
            final fill = focused(fillAt);
            expect(
              strongestContrast(label, focused, (_) => fill),
              greaterThanOrEqualTo(4.5),
              reason: 'the label on the fill',
            );

            // A mouse resting on the segment lays Material's hover tint over
            // the fill: the label still reads.
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            addTearDown(mouse.removePointer);
            await mouse.addPointer(location: label.center);
            await tester.pumpAndSettle();
            final hovered = await capturePixels(tester, boundary);
            final hoveredFill = hovered(fillAt);
            expect(
              strongestContrast(label, hovered, (_) => hoveredFill),
              greaterThanOrEqualTo(4.5),
              reason: 'the label on the fill under a hover',
            );
          });
        }
      }
    }

    /// The style a segment's [TextButton] reads from its theme, under
    /// [themeData].
    Future<ButtonStyle> segmentStyle(
      WidgetTester tester,
      ThemeData themeData,
    ) async {
      await host(tester, [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('One')),
            ButtonSegment(value: 1, label: Text('Two')),
          ],
          selected: const {0},
          onSelectionChanged: (_) {},
        ),
      ], themeData: themeData);
      return TextButtonTheme.of(tester.element(find.text('One'))).style!;
    }

    /// Every set of [states], each with and without the others.
    List<Set<WidgetState>> subsets(List<WidgetState> states) => [
      for (var mask = 0; mask < 1 << states.length; mask++)
        {
          for (var i = 0; i < states.length; i++)
            if (mask & (1 << i) != 0) states[i],
        },
    ];

    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets("the theme leaves every unfocused state as Material's, "
          '$name', (tester) async {
        final themed = build();
        final ours = await segmentStyle(tester, themed);
        final material = await segmentStyle(
          tester,
          themed.copyWith(
            segmentedButtonTheme: const SegmentedButtonThemeData(),
          ),
        );
        expect(themed.segmentedButtonTheme.style, isNotNull);

        for (final states in subsets([
          WidgetState.selected,
          WidgetState.hovered,
          WidgetState.pressed,
          WidgetState.disabled,
        ])) {
          expect(
            ours.foregroundColor?.resolve(states),
            material.foregroundColor?.resolve(states),
            reason: 'foregroundColor $states',
          );
          expect(
            ours.overlayColor?.resolve(states),
            material.overlayColor?.resolve(states),
            reason: 'overlayColor $states',
          );
          // Null, as Material's, where a segment shows what it sits on.
          // Transparent in its place drew the same pixels in every probe,
          // so the default is kept.
          expect(
            ours.backgroundColor?.resolve(states),
            material.backgroundColor?.resolve(states),
            reason: 'backgroundColor $states',
          );
        }
        // Focus alone gets no tint: the background shows it. Not null, which
        // would fall through to the text button's own focus tint.
        for (final selected in [true, false]) {
          final tint = selected
              ? themed.colorScheme.onSecondaryContainer
              : themed.colorScheme.onSurface;
          expect(
            ours.overlayColor?.resolve({
              WidgetState.focused,
              if (selected) WidgetState.selected,
            }),
            tint.withAlpha(0),
            reason: 'selected: $selected',
          );
        }
        // A press or hover that comes with focus keeps Material's overlay.
        // The focus fill is the segment's `backgroundColor`, not an overlay,
        // so the overlay has nothing of the fill's to add.
        for (final states
            in subsets([
              WidgetState.selected,
              WidgetState.hovered,
              WidgetState.pressed,
            ]).where(
              (s) => s.intersection({
                WidgetState.hovered,
                WidgetState.pressed,
              }).isNotEmpty,
            )) {
          final focused = {...states, WidgetState.focused};
          expect(
            ours.overlayColor?.resolve(focused),
            material.overlayColor?.resolve(focused),
            reason: 'overlayColor $focused',
          );
        }
      });
    }

    testWidgets("a focused segment's fill and label are both Material's while "
        'the highlight mode is touch', (tester) async {
      final ours = await segmentStyle(tester, theme);
      final material = await segmentStyle(
        tester,
        theme.copyWith(segmentedButtonTheme: const SegmentedButtonThemeData()),
      );
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );

      for (final selected in [true, false]) {
        final states = {
          WidgetState.focused,
          if (selected) WidgetState.selected,
        };
        final focus = selected
            ? BgeSegmentFocus.selected(theme.colorScheme)
            : BgeSegmentFocus.unselected(theme.colorScheme);
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        expect(ours.backgroundColor?.resolve(states), focus.background);
        expect(ours.foregroundColor?.resolve(states), focus.label);

        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTouch;
        for (final property
            in <
              WidgetStateProperty<Color?>? Function(
                ButtonStyle,
              )
            >[(s) => s.backgroundColor, (s) => s.foregroundColor]) {
          expect(
            property(ours)?.resolve(states),
            property(material)?.resolve(states),
            reason: 'by touch, selected: $selected',
          );
        }
      }
    });

    group("a focused segment's fill and label follow the highlight mode "
        'with the lease the app root holds', () {
      /// The segment's [Material], whose colour is its background and whose
      /// text style carries its label's colour.
      Material materialOfSegment(WidgetTester tester, Finder text) =>
          tester.widget<Material>(
            find
                .descendant(
                  of: find.ancestor(
                    of: text,
                    matching: find.byType(TextButton),
                  ),
                  matching: find.byType(Material),
                )
                .first,
          );

      for (final MapEntry(key: name, value: build) in themes.entries) {
        for (final selected in [true, false]) {
          final which = selected ? 'selected' : 'unselected';
          final segments = SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('One')),
              ButtonSegment(value: 1, label: Text('Two')),
            ],
            selected: const {0},
            onSelectionChanged: (_) {},
          );

          testWidgets("Tab, then a touch elsewhere: Material's rest, $name, "
              '$which', (tester) async {
            BgeFocusLease.attach();
            addTearDown(BgeFocusLease.detach);
            final themeData = build();
            final scheme = themeData.colorScheme;
            final focus = selected
                ? BgeSegmentFocus.selected(scheme)
                : BgeSegmentFocus.unselected(scheme);
            await host(tester, [segments], themeData: themeData);
            final text = find.text(selected ? 'One' : 'Two');
            // The theme leaves rest as Material's, pinned above.
            final rest = materialOfSegment(tester, text).color;

            await tab(tester);
            if (!selected) await tab(tester);
            await tester.pumpAndSettle();
            final node = Focus.of(tester.element(text));
            expect(node.hasPrimaryFocus, isTrue);
            expect(materialOfSegment(tester, text).color, focus.background);
            expect(
              materialOfSegment(tester, text).textStyle?.color,
              focus.label,
            );

            // A touch elsewhere: the segment keeps focus, and shows none.
            await tester.tapAt(empty);
            await tester.pumpAndSettle();
            expect(
              FocusManager.instance.highlightMode,
              FocusHighlightMode.touch,
            );
            expect(node.hasPrimaryFocus, isTrue);
            expect(
              materialOfSegment(tester, text).color,
              rest,
              reason: "Material's background at rest",
            );
            expect(
              materialOfSegment(tester, text).textStyle?.color,
              selected ? scheme.onSecondaryContainer : scheme.onSurface,
              reason: "Material's label",
            );
          });

          testWidgets('focused by touch, then Shift: the fill and its label, '
              '$name, $which', (tester) async {
            BgeFocusLease.attach();
            addTearDown(BgeFocusLease.detach);
            final themeData = build();
            final scheme = themeData.colorScheme;
            final focus = selected
                ? BgeSegmentFocus.selected(scheme)
                : BgeSegmentFocus.unselected(scheme);
            await host(tester, [segments], themeData: themeData);
            final text = find.text(selected ? 'One' : 'Two');
            final rest = materialOfSegment(tester, text).color;

            await tester.tapAt(empty);
            await tester.pump();
            expect(
              FocusManager.instance.highlightMode,
              FocusHighlightMode.touch,
            );
            final node = Focus.of(tester.element(text))..requestFocus();
            await tester.pumpAndSettle();
            expect(node.hasPrimaryFocus, isTrue);
            expect(
              materialOfSegment(tester, text).color,
              rest,
              reason: 'no focus shown by touch',
            );
            expect(
              materialOfSegment(tester, text).textStyle?.color,
              selected ? scheme.onSecondaryContainer : scheme.onSurface,
              reason: 'no focus shown by touch',
            );

            await tester.sendKeyEvent(LogicalKeyboardKey.shift);
            await tester.pumpAndSettle();
            expect(
              FocusManager.instance.highlightMode,
              FocusHighlightMode.traditional,
            );
            expect(node.hasPrimaryFocus, isTrue);
            expect(materialOfSegment(tester, text).color, focus.background);
            expect(
              materialOfSegment(tester, text).textStyle?.color,
              focus.label,
            );
          });
        }
      }
    });

    // The fill and the label read the highlight mode together, in one
    // build, so a touch that changes the mode can't take one away and leave
    // the other. In the app, the root's lease rebuilds the segment as the
    // mode changes, so it shows Material's rest (the group above). This
    // test holds no lease, so the segment keeps its fill until it next
    // builds, and the label must read on whatever it shows meanwhile.
    group(
      'a touch after Tab leaves the label readable on what is under it',
      () {
        for (final MapEntry(key: name, value: build) in themes.entries) {
          for (final selected in [true, false]) {
            final which = selected ? 'selected' : 'unselected';
            testWidgets('$name, $which', (tester) async {
              await host(tester, [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('One')),
                    ButtonSegment(value: 1, label: Text('Two')),
                  ],
                  selected: const {0},
                  onSelectionChanged: (_) {},
                ),
              ], themeData: build());
              final text = find.text(selected ? 'One' : 'Two');
              final label = tester.getRect(text);

              await tab(tester);
              if (!selected) await tab(tester);
              await tester.pumpAndSettle();
              expect(Focus.of(tester.element(text)).hasPrimaryFocus, isTrue);

              // A touch: startGesture's default kind.
              final touch = await tester.startGesture(empty);
              addTearDown(touch.up);
              // Long enough for an ink highlight the mode change ends to fade.
              await tester.pumpAndSettle();
              expect(
                FocusManager.instance.highlightMode,
                FocusHighlightMode.touch,
              );
              expect(Focus.of(tester.element(text)).hasPrimaryFocus, isTrue);
              final pixels = await capturePixels(tester, boundary);
              final under = pixels(Offset(label.right + 3, label.center.dy));
              expect(
                strongestContrast(label, pixels, (_) => under),
                greaterThanOrEqualTo(4.5),
              );
            });
          }
        }
      },
    );

    // A mouse already resting on a segment when Tab focuses it. The ink
    // well makes its focus highlight with every state the segment is in, so
    // the highlight takes the hover's 8% strength, and keeps it after the
    // mouse leaves. The label is checked on whatever is drawn, while
    // hovered and after.
    group('a hover already on a segment when focus arrives leaves the label '
        'readable', () {
      for (final MapEntry(key: name, value: build) in themes.entries) {
        for (final selected in [true, false]) {
          final which = selected ? 'selected' : 'unselected';
          testWidgets('$name, $which', (tester) async {
            await host(tester, [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('One')),
                  ButtonSegment(value: 1, label: Text('Two')),
                ],
                selected: const {0},
                onSelectionChanged: (_) {},
              ),
            ], themeData: build());
            final text = find.text(selected ? 'One' : 'Two');
            final label = tester.getRect(text);
            final at = Offset(label.right + 3, label.center.dy);
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            addTearDown(mouse.removePointer);
            await mouse.addPointer(location: label.center);
            await tester.pumpAndSettle();

            await tab(tester);
            if (!selected) await tab(tester);
            await tester.pumpAndSettle();
            expect(Focus.of(tester.element(text)).hasPrimaryFocus, isTrue);

            for (final when in ['hovered', 'after the hover']) {
              if (when == 'after the hover') {
                await mouse.moveTo(empty);
                await tester.pumpAndSettle();
              }
              final pixels = await capturePixels(tester, boundary);
              final under = pixels(at);
              expect(
                strongestContrast(label, pixels, (_) => under),
                greaterThanOrEqualTo(4.5),
                reason: '$when, under $under',
              );
            }
          });
        }
      }
    });

    test('two themes built from one palette give equal segment styles', () {
      final first = BgeTheme.from(BgePalette.storm);
      final second = BgeTheme.from(BgePalette.storm);
      for (final (a, b) in [
        (first.light, second.light),
        (first.dark, second.dark),
        (first.highContrastLight, second.highContrastLight),
        (first.highContrastDark, second.highContrastDark),
      ]) {
        expect(a.segmentedButtonTheme, b.segmentedButtonTheme);
        expect(
          a.segmentedButtonTheme.hashCode,
          b.segmentedButtonTheme.hashCode,
        );
      }
    });
  });

  // #761: a chip shows keyboard focus by a ring its theme's side draws, as it
  // shows focus by Material's faint tint alone without it.
  group("a chip's keyboard focus is a ring, 3:1 against its fill (#761)", () {
    final themes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };
    final backgrounds = <String, Color Function(ColorScheme)>{
      'surface': (s) => s.surface,
      'surfaceContainerLow': (s) => s.surfaceContainerLow,
      'surfaceContainerHigh': (s) => s.surfaceContainerHigh,
    };

    /// Each chip type that takes focus, labelled "Entry", selected or not.
    /// An action chip can't be selected.
    final chips =
        <String, Widget Function({required bool selected, bool enabled})>{
          'FilterChip': ({required selected, enabled = true}) => FilterChip(
            key: goKey,
            label: const Text('Entry'),
            selected: selected,
            onSelected: enabled ? (_) {} : null,
          ),
          'ChoiceChip': ({required selected, enabled = true}) => ChoiceChip(
            key: goKey,
            label: const Text('Entry'),
            selected: selected,
            onSelected: enabled ? (_) {} : null,
          ),
          'InputChip': ({required selected, enabled = true}) => InputChip(
            key: goKey,
            label: const Text('Entry'),
            selected: selected,
            isEnabled: enabled,
            onSelected: (_) {},
          ),
          'ActionChip': ({required selected, enabled = true}) => ActionChip(
            key: goKey,
            label: const Text('Entry'),
            onPressed: enabled ? () {} : null,
          ),
        };
    bool selectable(String chip) => chip != 'ActionChip';

    // From the probe (#761), with a mouse resting on the chip: under the
    // chip's focus and hover tints, `primary` stands 3.61 on a selected
    // chip's fill in high-contrast light, but 2.88 in light, 1.88 in dark
    // and 2.20 in high-contrast dark.
    final selectedRing = <String, Color Function(ColorScheme)>{
      'light': (s) => s.onSecondaryContainer,
      'dark': (s) => s.onSecondaryContainer,
      'highContrastLight': (s) => s.primary,
      'highContrastDark': (s) => s.onSecondaryContainer,
    };

    /// The chip's resolved side, as its [Material] paints it.
    BorderSide sideOf(WidgetTester tester) =>
        (tester.widget<Material>(materialOf(goKey)).shape! as OutlinedBorder)
            .side;

    /// A ring in [color], half inside the chip's edge, so its inset is the
    /// 1px side's at rest.
    BorderSide ringOf(Color color) => BorderSide(
      color: color,
      width: tokens.focusOutlineWidth,
      strokeAlign: BorderSide.strokeAlignCenter,
    );

    for (final MapEntry(key: name, value: build) in themes.entries) {
      for (final MapEntry(key: chip, value: make) in chips.entries) {
        for (final selected in [false, if (selectable(chip)) true]) {
          final which = selected ? 'selected' : 'unselected';
          // A selected chip has its own fill; an unselected one shows what
          // it sits on.
          final on = selected
              ? {'surface': backgrounds['surface']!}
              : backgrounds;
          for (final MapEntry(key: where, value: background) in on.entries) {
            testWidgets('$chip, $name, $which, on $where', (tester) async {
              final themeData = build();
              final scheme = themeData.colorScheme;
              await host(tester, [
                ColoredBox(
                  color: background(scheme),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: make(selected: selected),
                  ),
                ),
              ], themeData: themeData);
              final shape = tester.getRect(materialOf(goKey));
              final atRest = await capturePixels(tester, boundary);

              await tab(tester);
              await tester.pumpAndSettle();
              expect(
                Focus.of(tester.element(find.text('Entry'))).hasPrimaryFocus,
                isTrue,
              );
              expect(
                sideOf(tester),
                ringOf(
                  selected ? selectedRing[name]!(scheme) : scheme.primary,
                ),
              );
              // The chip pads its content by its side's inset, so a ring
              // inside the edge would grow it, and move what is beside it.
              expect(
                tester.getRect(materialOf(goKey)),
                shape,
                reason: 'focus keeps the chip its size',
              );
              final focused = await capturePixels(tester, boundary);

              // On the ring's inner half, and just inside it on the fill,
              // both under the chip's own focus tint.
              final onRing = Offset(shape.left + 0.5, shape.center.dy);
              final onFill = Offset(
                shape.left + tokens.focusOutlineWidth + 2,
                shape.center.dy,
              );
              expect(
                Wcag.contrastRatio(focused(onRing), focused(onFill)),
                greaterThanOrEqualTo(3.0),
                reason: 'the ring on the fill',
              );
              expect(
                strongestContrast(shape, atRest, focused),
                greaterThanOrEqualTo(3.0),
                reason: 'focused against rest',
              );

              // A mouse resting on the chip lays Material's hover tint over
              // the focus tint: the ring still stands 3:1, selected or not.
              // An unselected chip in a dialog in dark measures 3.52 here.
              // Worked out over the dialog's colour it would be 2.90, but an
              // unselected chip's own Material paints `surface` under the
              // tints, whatever it sits on.
              final mouse = await tester.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              addTearDown(mouse.removePointer);
              await mouse.addPointer(
                location: tester.getCenter(find.text('Entry')),
              );
              await tester.pumpAndSettle();
              expect(
                sideOf(tester),
                ringOf(
                  selected ? selectedRing[name]!(scheme) : scheme.primary,
                ),
                reason: 'a hover keeps the ring',
              );
              final hovered = await capturePixels(tester, boundary);
              expect(
                Wcag.contrastRatio(hovered(onRing), hovered(onFill)),
                greaterThanOrEqualTo(3.0),
                reason: 'the ring on the fill under a hover',
              );
            });
          }
        }
      }
    }

    // The check #50's audit pinned, skipped until now: the filter chip's
    // focus measured 1.32 to 1.40 from its rest.
    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets("a filter chip's keyboard focus differs from its rest by "
          '3:1, $name', (tester) async {
        await host(tester, [
          FilterChip(
            key: goKey,
            label: const Text('Entry'),
            onSelected: (_) {},
          ),
        ], themeData: build());
        final rect = tester.getRect(find.byKey(goKey));
        final atRest = await capturePixels(tester, boundary);

        await tab(tester);
        await tester.pumpAndSettle();
        expect(
          Focus.of(tester.element(find.text('Entry'))).hasPrimaryFocus,
          isTrue,
        );
        final focused = await capturePixels(tester, boundary);

        // Anywhere the focus shows: a fill, a ring, an edge.
        expect(
          strongestContrast(rect, atRest, focused),
          greaterThanOrEqualTo(3.0),
        );
      });
    }

    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets("the theme leaves an unfocused chip's side as Material's, "
          '$name', (tester) async {
        final themed = build();
        final material = themed.copyWith(chipTheme: const ChipThemeData());
        expect(themed.chipTheme.side, isNotNull);

        /// [chip]'s side under [themeData] at rest, hovered by a mouse, and
        /// pressed.
        Future<List<BorderSide>> sides(
          ThemeData themeData,
          Widget chip,
        ) async {
          await host(tester, [chip], themeData: themeData);
          final atRest = sideOf(tester);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(
            location: tester.getCenter(find.text('Entry')),
          );
          await tester.pumpAndSettle();
          final hovered = sideOf(tester);
          await mouse.down(tester.getCenter(find.text('Entry')));
          await tester.pump();
          final pressed = sideOf(tester);
          await mouse.up();
          await mouse.removePointer();
          await tester.pumpAndSettle();
          return [atRest, hovered, pressed];
        }

        for (final MapEntry(key: chip, value: make) in chips.entries) {
          for (final selected in [false, if (selectable(chip)) true]) {
            for (final enabled in [true, false]) {
              final widget = make(selected: selected, enabled: enabled);
              expect(
                await sides(themed, widget),
                await sides(material, widget),
                reason: '$chip, selected: $selected, enabled: $enabled',
              );
            }
          }
        }
      });
    }

    test(
      'the four themes lerp into each other, as a theme change animates',
      () {
        // Mid-animation, Flutter resolves each side with no state, and throws
        // where both resolve to null.
        for (final a in themes.values) {
          for (final b in themes.values) {
            expect(() => ThemeData.lerp(a(), b(), 0.5), returnsNormally);
          }
        }
      },
    );

    test('two themes built from one palette have equal chip themes', () {
      final again = BgeTheme.from(BgePalette.storm);
      expect(again.light.chipTheme, BgeTheme.light().chipTheme);
      expect(
        again.highContrastDark.chipTheme,
        BgeTheme.highContrastDark().chipTheme,
      );
      expect(
        BgeTheme.light().chipTheme,
        isNot(BgeTheme.dark().chipTheme),
      );
    });

    testWidgets("a focused chip's ring follows the highlight mode", (
      tester,
    ) async {
      BgeFocusLease.attach();
      addTearDown(BgeFocusLease.detach);
      await host(tester, [chips['FilterChip']!(selected: false)]);
      await tab(tester);
      final focus = FocusManager.instance.primaryFocus;
      expect(sideOf(tester), ringOf(ring), reason: 'Tab rings it');

      // A touch elsewhere: the chip keeps focus, and the ring goes.
      await tester.tapAt(empty);
      await tester.pump();
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(
        sideOf(tester),
        BorderSide(color: theme.colorScheme.outlineVariant),
        reason: "Material's side after a touch",
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(sideOf(tester), ringOf(ring), reason: 'a key press');
    });

    group('with the lease the app root holds', () {
      testWidgets(
        'no ring after a mouse press while the lease is held',
        (tester) async {
          BgeFocusLease.attach();
          addTearDown(BgeFocusLease.detach);
          await host(tester, [chips['FilterChip']!(selected: false)]);
          final material = BorderSide(color: theme.colorScheme.outlineVariant);
          await tab(tester);
          final focus = FocusManager.instance.primaryFocus;
          expect(sideOf(tester), ringOf(ring), reason: 'Tab rings it');

          // A press elsewhere leaves focus on the chip, and takes the ring.
          await tester.tapAt(empty, kind: PointerDeviceKind.mouse);
          await tester.pump();
          expect(FocusManager.instance.primaryFocus, same(focus));
          expect(
            FocusManager.instance.highlightMode,
            FocusHighlightMode.traditional,
          );
          expect(sideOf(tester), material, reason: 'the press');

          // A shortcut isn't navigation: Meta+C leaves it hidden.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pump();
          expect(sideOf(tester), material, reason: 'Meta+C');

          await tester.sendKeyEvent(LogicalKeyboardKey.shift);
          await tester.pump();
          expect(sideOf(tester), ringOf(ring), reason: 'a key press');

          // A press on the chip itself, which focus stays on.
          await tester.tap(find.byKey(goKey), kind: PointerDeviceKind.mouse);
          await tester.pumpAndSettle();
          expect(FocusManager.instance.primaryFocus, same(focus));
          expect(
            sideOf(tester),
            BorderSide(color: theme.colorScheme.outlineVariant),
            reason: 'a press on the chip',
          );
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );

      testWidgets(
        'a mouse press on a page with no ring built, then focus landing on a '
        'ringed control, shows no ring',
        (tester) async {
          // Review Focus 4 of #761's plan: the chip's ring has no lifecycle
          // to watch for the press, and here no ring is built to watch for
          // it either. The lease records it.
          BgeFocusLease.attach();
          addTearDown(BgeFocusLease.detach);
          const nothing = Text('Nothing to focus');

          await host(tester, [nothing]);
          await tester.tapAt(empty, kind: PointerDeviceKind.mouse);
          await tester.pump();
          await host(tester, [
            FilterChip(
              key: goKey,
              autofocus: true,
              label: const Text('Entry'),
              onSelected: (_) {},
            ),
          ]);
          expect(
            Focus.of(tester.element(find.text('Entry'))).hasPrimaryFocus,
            isTrue,
          );
          expect(
            sideOf(tester),
            BorderSide(color: theme.colorScheme.outlineVariant),
            reason: 'focus after the press',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.shift);
          await tester.pump();
          expect(sideOf(tester), ringOf(ring), reason: 'a key press');

          // A button's ring, built after the press, too.
          await host(tester, [nothing]);
          await tester.tapAt(empty, kind: PointerDeviceKind.mouse);
          await tester.pump();
          await host(tester, [
            TextButton(
              key: goKey,
              autofocus: true,
              onPressed: () {},
              child: const Text('Go'),
            ),
          ]);
          expect(painters(tester, find.byKey(goKey)).single.color, isNull);
          await tester.sendKeyEvent(LogicalKeyboardKey.shift);
          await tester.pump();
          expect(painters(tester, find.byKey(goKey)).single.color, ring);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      );
    });
  });

  // What #50's drafted findings want, skipped until each is fixed, so the gap
  // stays visible in the suite. Each is written against what a user sees
  // rather than against today's ring, so a fix of any shape passes it. Each
  // sits in a `group` so that its skip can carry the reason: `testWidgets`
  // takes only a bool.
  group('focus the ring does not reach yet (#50)', () {
    final schemes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };

    group(
      'a text button label that wraps at 320dp and 2.0 text keeps every '
      'glyph pixel',
      skip: 'see #764',
      () {
        testWidgets(
          'against the same button with Clip.none',
          (tester) async {
            // The ring's builder makes Flutter clip `TextButton()` to its
            // stadium, and a two-line label reaches the curved ends. The same
            // button with `Clip.none` draws the label whole.
            tester.view.physicalSize = const Size(320, 300);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            const label = 'Loading more games…';

            Future<Color Function(Offset)> draw(Clip? clip) async {
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme,
                  home: MediaQuery(
                    data: const MediaQueryData(
                      size: Size(320, 300),
                      textScaler: TextScaler.linear(2),
                    ),
                    child: RepaintBoundary(
                      key: boundary,
                      child: Scaffold(
                        body: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              TextButton(
                                key: goKey,
                                clipBehavior: clip,
                                onPressed: () {},
                                child: const Text(label),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              return capturePixels(tester, boundary);
            }

            final themed = await draw(null);
            final rect = tester.getRect(find.byKey(goKey));
            final lineTops = tester
                .renderObject<RenderParagraph>(find.text(label))
                .getBoxesForSelection(
                  const TextSelection(
                    baseOffset: 0,
                    extentOffset: label.length,
                  ),
                )
                .map((box) => box.top)
                .toSet();
            expect(
              lineTops,
              hasLength(greaterThan(1)),
              reason: 'the label wraps',
            );
            final whole = await draw(Clip.none);

            final cut = pixelCentres(rect).where((p) => themed(p) != whole(p));
            expect(cut, isEmpty, reason: 'glyph pixels the clip cut away');
          },
        );
      },
    );

    // A drawer entry shows focus as a fill alone. The filter chip pinned
    // beside it is ringed now (#761), and its check is in the chips' group.
    group(
      "a drawer entry's keyboard focus differs from its rest by 3:1",
      skip: 'see #761',
      () {
        // Labelled "Entry", its only stop.
        final controls = <String, Widget>{
          'NavigationDrawerDestination': const SizedBox(
            height: 200,
            child: NavigationDrawer(
              children: [
                NavigationDrawerDestination(
                  key: goKey,
                  icon: Icon(Icons.home),
                  label: Text('Entry'),
                ),
              ],
            ),
          ),
        };
        for (final MapEntry(key: control, value: widget) in controls.entries) {
          for (final MapEntry(key: name, value: build) in schemes.entries) {
            testWidgets('$control, $name', (tester) async {
              await host(tester, [widget], themeData: build());
              final rect = tester.getRect(find.byKey(goKey));
              final atRest = await capturePixels(tester, boundary);

              await tab(tester);
              await tester.pumpAndSettle();
              expect(
                Focus.of(tester.element(find.text('Entry'))).hasPrimaryFocus,
                isTrue,
              );
              final focused = await capturePixels(tester, boundary);

              // Anywhere the focus shows: a fill, a ring, an edge.
              expect(
                strongestContrast(rect, atRest, focused),
                greaterThanOrEqualTo(3.0),
              );
            });
          }
        }
      },
    );
  });
}
