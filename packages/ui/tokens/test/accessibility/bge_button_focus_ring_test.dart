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

  /// What is drawn now, as a colour at each point of the window.
  Future<Color Function(Offset)> capture(WidgetTester tester) async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final (width, bytes) = (await tester.runAsync(() async {
      final image = await render.toImage();
      final bytes = (await image.toByteData())!;
      final width = image.width;
      image.dispose();
      return (width, bytes);
    }))!;
    Color colourAt(Offset point) {
      final at = (point.dy.floor() * width + point.dx.floor()) * 4;
      return Color.fromARGB(
        bytes.getUint8(at + 3),
        bytes.getUint8(at),
        bytes.getUint8(at + 1),
        bytes.getUint8(at + 2),
      );
    }

    return colourAt;
  }

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

    final atRest = await capture(tester);
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
      final pixels = await capture(tester);
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

  // What #50's drafted findings want, skipped until each is fixed, so the gap
  // stays visible in the suite. Each is written against what a user sees
  // rather than against today's ring, so a fix of any shape passes it. Each
  // sits in a `group` so that its skip can carry the reason: `testWidgets`
  // takes only a bool.
  group('focus the ring does not reach yet (#50)', () {
    /// Whether [c] is within a little of [target].
    bool near(Color c, Color target) =>
        (c.r - target.r).abs() < 0.05 &&
        (c.g - target.g).abs() < 0.05 &&
        (c.b - target.b).abs() < 0.05;

    /// The points of [rect], one per pixel.
    Iterable<Offset> pixelsOf(Rect rect) sync* {
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
          yield Offset(x + 0.5, y + 0.5);
        }
      }
    }

    final schemes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };

    group(
      "a list row's keyboard focus differs from its rest by 3:1",
      skip: 'see <A11Y-1>',
      () {
        for (final MapEntry(key: name, value: build) in schemes.entries) {
          testWidgets(
            name,
            (tester) async {
              await host(tester, [
                ListTile(key: goKey, onTap: () {}, title: const Text('Row')),
              ], themeData: build());
              final rect = tester.getRect(find.byKey(goKey));
              final atRest = await capture(tester);

              await tab(tester);
              await tester.pumpAndSettle();
              expect(
                Focus.of(tester.element(find.text('Row'))).hasPrimaryFocus,
                isTrue,
              );
              final focused = await capture(tester);

              // Anywhere the focus shows: a fill, a ring, an edge.
              var strongest = 1.0;
              for (final point in pixelsOf(rect)) {
                final ratio = Wcag.contrastRatio(atRest(point), focused(point));
                if (ratio > strongest) strongest = ratio;
              }
              expect(strongest, greaterThanOrEqualTo(3.0));
            },
          );
        }
      },
    );

    group(
      "a segmented button's segment is ringed on keyboard focus",
      skip: 'see <A11Y-2>',
      () {
        testWidgets(
          'its first segment',
          (tester) async {
            await host(tester, [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('One')),
                  ButtonSegment(value: 1, label: Text('Two')),
                ],
                selected: const {0},
                onSelectionChanged: (_) {},
              ),
            ]);
            final segment = find
                .descendant(
                  of: find.byType(SegmentedButton<int>),
                  matching: find.byType(TextButton),
                )
                .first;
            // The ring may sit on the edge or outside it.
            final around = tester
                .getRect(segment)
                .inflate(tokens.focusRingGap + tokens.focusOutlineWidth);
            int ringPixels(Color Function(Offset) pixels) =>
                pixelsOf(around).where((p) => near(pixels(p), ring)).length;
            final atRest = ringPixels(await capture(tester));

            await tab(tester);
            await tester.pumpAndSettle();
            expect(
              Focus.of(tester.element(find.text('One'))).hasPrimaryFocus,
              isTrue,
            );

            expect(ringPixels(await capture(tester)), greaterThan(atRest));
          },
        );
      },
    );

    group(
      'a text button label that wraps at 320dp and 2.0 text keeps every '
      'glyph pixel',
      skip: 'see <A11Y-16>',
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
              return capture(tester);
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

            final cut = pixelsOf(rect).where((p) => themed(p) != whole(p));
            expect(cut, isEmpty, reason: 'glyph pixels the clip cut away');
          },
        );
      },
    );

    group(
      'an extended floating action button is ringed on keyboard focus',
      skip: 'see <A11Y-10>',
      () {
        testWidgets('FloatingActionButton.extended', (tester) async {
          await host(tester, [
            FloatingActionButton.extended(
              key: goKey,
              onPressed: () {},
              label: const Text('Create'),
            ),
          ]);
          // The ring may sit on the edge or outside it.
          final around = tester
              .getRect(find.byKey(goKey))
              .inflate(tokens.focusRingGap + tokens.focusOutlineWidth);
          int ringPixels(Color Function(Offset) pixels) =>
              pixelsOf(around).where((p) => near(pixels(p), ring)).length;
          final atRest = ringPixels(await capture(tester));

          await tab(tester);
          await tester.pumpAndSettle();
          expect(
            Focus.of(tester.element(find.text('Create'))).hasPrimaryFocus,
            isTrue,
          );

          expect(ringPixels(await capture(tester)), greaterThan(atRest));
        });
      },
    );

    // A drawer entry and a filter chip show focus as a fill alone.
    group(
      "a drawer entry's and a filter chip's keyboard focus differs from their "
      'rest by 3:1',
      skip: 'see <A11Y-11>',
      () {
        // Each labelled "Entry", its only stop.
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
          'FilterChip': FilterChip(
            key: goKey,
            label: const Text('Entry'),
            onSelected: (_) {},
          ),
        };
        for (final MapEntry(key: control, value: widget) in controls.entries) {
          for (final MapEntry(key: name, value: build) in schemes.entries) {
            testWidgets('$control, $name', (tester) async {
              await host(tester, [widget], themeData: build());
              final rect = tester.getRect(find.byKey(goKey));
              final atRest = await capture(tester);

              await tab(tester);
              await tester.pumpAndSettle();
              expect(
                Focus.of(tester.element(find.text('Entry'))).hasPrimaryFocus,
                isTrue,
              );
              final focused = await capture(tester);

              // Anywhere the focus shows: a fill, a ring, an edge.
              final strongest = pixelsOf(rect)
                  .map((p) => Wcag.contrastRatio(atRest(p), focused(p)))
                  .fold<double>(1, (a, b) => a > b ? a : b);
              expect(strongest, greaterThanOrEqualTo(3.0));
            });
          }
        }
      },
    );
  });
}
