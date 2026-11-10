import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(
  WidgetTester tester,
  Widget child, {
  double textScale = 1,
  Size size = const Size(600, 800),
}) => hostAtSize(
  tester,
  Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
  size: size,
  textScale: textScale,
);

/// What a cover's expansions badge says and does in these tests (#711).
BgeCoverExpansions _expansions({
  int count = 2,
  bool expanded = false,
  VoidCallback? onToggle,
}) => BgeCoverExpansions(
  count: count,
  expanded: expanded,
  onToggle: onToggle ?? () {},
  label: 'Azul expansions, $count',
  showLabel: 'Show expansions',
  hideLabel: 'Hide expansions',
);

/// The expansions badge.
final Finder _badge = find.byKey(BgeCoverTile.expansionsBadgeKey);

/// The tile's node, the one its picture is merged into.
///
/// Found from the picture, not the tile: with a badge, the tile's widget
/// holds two nodes, the cover's and the badge's, and has none of its own.
SemanticsNode _tileNode(WidgetTester tester) =>
    tester.getSemantics(find.byType(BgeThumbnail));

/// Performs the custom action called [label] on [node].
void _performCustomAction(SemanticsNode node, String label) =>
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label)),
    );

/// The colour drawn at [at], a global position, under [boundary].
Future<Color> _colourAt(
  WidgetTester tester,
  GlobalKey boundary,
  Offset at,
) async {
  final local = at - tester.getTopLeft(find.byKey(boundary));
  return pixel(await _paintUnder(tester, boundary), local.dx, local.dy);
}

/// What is drawn under [boundary] now, as `(width, RGBA bytes)`.
Future<(int, ByteData)> _paintUnder(
  WidgetTester tester,
  GlobalKey boundary,
) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await render.toImage();
    return (image.width, (await image.toByteData())!);
  }))!;
}

/// The colour at ([x], [y]) in [image].
Color pixel((int, ByteData) image, double x, double y) {
  final (width, bytes) = image;
  final at = (y.floor() * width + x.floor()) * 4;
  return Color.fromARGB(
    bytes.getUint8(at + 3),
    bytes.getUint8(at),
    bytes.getUint8(at + 1),
    bytes.getUint8(at + 2),
  );
}

void main() {
  testWidgets('one node, labelled by the label, with a tap action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(tester, BgeCoverTile(label: 'Azul', onTap: () {})),
    );

    final tile = tester.getSemantics(find.byType(BgeCoverTile));
    expect(tile, isSemantics(label: 'Azul', hasTapAction: true));
    expect(tile.childrenCount, 0);
    // The picture is decorative: it is the same node, or none.
    expect(tester.getSemantics(find.byType(BgeThumbnail)).id, tile.id);
    handle.dispose();
  });

  testWidgets('with stackCount it keeps one tap target and its label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      _host(
        tester,
        SizedBox(
          width: 120,
          child: BgeCoverTile(
            label: 'Azul, 3 copies',
            stackCount: 3,
            extent: null,
            onTap: () => taps++,
          ),
        ),
      ),
    );

    expect(find.byType(BgeStackMarker), findsOneWidget);
    expect(find.byType(InkWell), findsOneWidget);
    expect(find.bySemanticsLabel('3'), findsNothing);
    final tile = tester.getSemantics(find.byType(BgeCoverTile));
    expect(tile, isSemantics(label: 'Azul, 3 copies', hasTapAction: true));
    expect(tile.childrenCount, 0);
    expect(tester.getSize(find.byType(BgeCoverTile)), const Size.square(120));
    await tester.tap(find.byType(BgeCoverTile));
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('a tap calls onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(tester, BgeCoverTile(label: 'Azul', onTap: () => taps++)),
    );

    await tester.tap(find.byType(BgeCoverTile));

    expect(taps, 1);
  });

  testWidgets('without onTap it offers nothing to press', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(tester, const BgeCoverTile(label: 'Azul')));

    expect(
      tester.getSemantics(find.byType(BgeCoverTile)),
      isSemantics(label: 'Azul', hasTapAction: false, isFocusable: false),
    );
    handle.dispose();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('the tile is 120 square at 1.0 and at 2.0 text ($scale)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(tester, const BgeCoverTile(label: 'Azul'), textScale: scale),
      );

      expect(tester.getSize(find.byType(BgeCoverTile)), const Size(120, 120));
      expect(tester.getSize(find.byType(BgeThumbnail)), const Size(120, 120));
    });
  }

  testWidgets('with no extent it fills its width', (tester) async {
    await tester.pumpWidget(
      _host(
        tester,
        const SizedBox(
          width: 200,
          child: BgeCoverTile(label: 'Azul', extent: null),
        ),
      ),
    );

    expect(tester.getSize(find.byType(BgeCoverTile)), const Size(200, 200));
    expect(tester.getSize(find.byType(BgeThumbnail)), const Size(200, 200));
  });

  testWidgets('no text is drawn', (tester) async {
    await tester.pumpWidget(
      _host(tester, BgeCoverTile(label: 'Azul', onTap: () {})),
    );

    expect(
      find.descendant(
        of: find.byType(BgeCoverTile),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
    expect(find.text('Azul'), findsNothing);
  });

  testWidgets('its target is at least 48 square', (tester) async {
    await tester.pumpWidget(
      _host(tester, BgeCoverTile(label: 'Azul', extent: 20, onTap: () {})),
    );

    final size = tester.getSize(find.byType(InkWell));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  group('what a keyboard or a pointer shows', () {
    final boundary = GlobalKey();

    /// The tile at the top left of the page, drawn through [boundary] so that
    /// a test can read the pixels the user would see.
    ///
    /// A tap calls [onTap] with a context under the app's navigator.
    Future<Rect> showTile(
      WidgetTester tester, {
      void Function(BuildContext context)? onTap,
      BgeCoverExpansions? expansions,
    }) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: Builder(
                  builder: (context) => BgeCoverTile(
                    label: 'Azul',
                    onTap: () => onTap?.call(context),
                    expansions: expansions,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getRect(find.byType(BgeCoverTile));
    }

    /// Whether the tile holds focus.
    final focused = find.descendant(
      of: find.byType(BgeCoverTile),
      matching: find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode != null && w.focusNode!.hasFocus,
      ),
    );

    /// Where a mouse rests, away from the tile.
    const away = Offset(300, 600);

    /// A mouse, connected and resting [away] from the tile.
    Future<TestGesture> connectMouse(WidgetTester tester) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: away);
      addTearDown(mouse.removePointer);
      return mouse;
    }

    /// Clicks at [at] with [mouse], then moves it away again, so that what is
    /// drawn over the cover afterwards is not the hover's.
    ///
    /// The button is held for 50ms, as a quick click's is, so frames pass
    /// while it is down.
    Future<void> click(
      WidgetTester tester,
      TestGesture mouse,
      Offset at,
    ) async {
      await mouse.moveTo(at);
      await mouse.down(at);
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.up();
      await mouse.moveTo(away);
      await tester.pumpAndSettle();
    }

    /// What is drawn now, as `(width, RGBA bytes)`.
    Future<(int, ByteData)> paint(WidgetTester tester) =>
        _paintUnder(tester, boundary);

    /// Tabs to the tile, as a keyboard user would.
    Future<void> focusTile(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
    }

    final primary = BgeTheme.light().colorScheme.primary;

    setUp(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
    });

    testWidgets('a focused tile is ringed over its cover', (tester) async {
      final tile = await showTile(tester);
      // Just inside the cover's left edge, halfway down it.
      final onTheRing = Offset(tile.left + 1, tile.top + 60);
      expect(
        pixel(await paint(tester), onTheRing.dx, onTheRing.dy),
        isNot(primary),
      );

      await focusTile(tester);

      expect(
        pixel(await paint(tester), onTheRing.dx, onTheRing.dy),
        primary,
        reason: 'the cover is opaque, so the ring has to be drawn over it',
      );
    });

    testWidgets("the ring goes when focus is only a pointer's", (
      tester,
    ) async {
      final tile = await showTile(tester);
      final onTheRing = Offset(tile.left + 1, tile.top + 60);
      await focusTile(tester);
      expect(pixel(await paint(tester), onTheRing.dx, onTheRing.dy), primary);

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      await tester.pumpAndSettle();

      expect(
        pixel(await paint(tester), onTheRing.dx, onTheRing.dy),
        isNot(primary),
      );
    });

    testWidgets('a tile only a pointer focused is not ringed', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;
      final tile = await showTile(tester);

      await focusTile(tester);

      expect(
        pixel(await paint(tester), tile.left + 1, tile.top + 60),
        isNot(primary),
      );
    });

    testWidgets('hovering tints the cover', (tester) async {
      final tile = await showTile(tester);
      final coverCentre = Offset(tile.left + 60, tile.top + 30);
      final before = pixel(await paint(tester), coverCentre.dx, coverCentre.dy);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(coverCentre);
      await tester.pumpAndSettle();

      expect(
        pixel(await paint(tester), coverCentre.dx, coverCentre.dy),
        isNot(before),
      );
    });

    testWidgets('a pointer tap leaves the tile focused and unringed', (
      tester,
    ) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      final tile = await showTile(tester);

      await tester.tap(find.byType(BgeCoverTile));
      await tester.pumpAndSettle();

      expect(focused, findsOneWidget);
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
      expect(
        pixel(await paint(tester), tile.left + 1, tile.top + 60),
        isNot(primary),
      );
    });

    testWidgets('a touch leaves the ring to the highlight mode, and waits '
        'on no key press', (tester) async {
      // Under a touch-only highlight the mode hides the ring itself. The
      // group's keyboard highlight shows whether the tile hid it too, which
      // only a mouse or a trackpad needs: a touch that did would also leave
      // a key handler behind on a phone with no keyboard to clear it.
      final tile = await showTile(tester);

      await tester.tap(find.byType(BgeCoverTile));
      await tester.pumpAndSettle();

      expect(focused, findsOneWidget);
      expect(pixel(await paint(tester), tile.left + 1, tile.top + 60), primary);
    });

    testWidgets('a mouse click leaves the tile focused, unringed and '
        'untinted, until a key is pressed', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      final tile = await showTile(tester);
      final onTheRing = Offset(tile.left + 1, tile.top + 60);
      final coverCentre = Offset(tile.left + 60, tile.top + 30);
      final unfocused = pixel(
        await paint(tester),
        coverCentre.dx,
        coverCentre.dy,
      );

      await click(tester, await connectMouse(tester), coverCentre);

      expect(focused, findsOneWidget);
      // A mouse leaves the highlight mode as it was, which on a desktop is
      // the keyboard's.
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      final clicked = await paint(tester);
      expect(pixel(clicked, onTheRing.dx, onTheRing.dy), isNot(primary));
      expect(
        pixel(clicked, coverCentre.dx, coverCentre.dy),
        unfocused,
        reason: 'no focus tint for focus a pointer gave',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(focused, findsOneWidget);
      expect(pixel(await paint(tester), onTheRing.dx, onTheRing.dy), primary);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('after a mouse click, a shortcut held with Meta or Control '
        'is not the keyboard coming back', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      final tile = await showTile(tester);
      final onTheRing = Offset(tile.left + 1, tile.top + 60);
      await click(
        tester,
        await connectMouse(tester),
        Offset(tile.left + 60, tile.top + 30),
      );

      for (final modifier in [
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.controlLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();

        expect(
          pixel(await paint(tester), onTheRing.dx, onTheRing.dy),
          isNot(primary),
          reason: '$modifier+C',
        );
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(pixel(await paint(tester), onTheRing.dx, onTheRing.dy), primary);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('after a mouse click, focus that comes back from a closed '
        'pop-up is unringed', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      final tile = await showTile(
        tester,
        onTap: (context) => showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('over the tile')),
        ),
      );
      final onTheRing = Offset(tile.left + 1, tile.top + 60);
      final coverCentre = Offset(tile.left + 60, tile.top + 30);
      final unfocused = pixel(
        await paint(tester),
        coverCentre.dx,
        coverCentre.dy,
      );

      final mouse = await connectMouse(tester);
      await click(tester, mouse, coverCentre);
      expect(find.text('over the tile'), findsOneWidget);
      // Closed by a click on the barrier, beside the dialog.
      await click(tester, mouse, const Offset(8, 700));
      expect(find.text('over the tile'), findsNothing);

      expect(focused, findsOneWidget);
      final back = await paint(tester);
      expect(pixel(back, onTheRing.dx, onTheRing.dy), isNot(primary));
      expect(pixel(back, coverCentre.dx, coverCentre.dy), unfocused);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets("the badge's focus is ringed from the keyboard, not after a "
        'click', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      final tile = await showTile(tester, expansions: _expansions());
      final badgeFocused = find.descendant(
        of: _badge,
        matching: find.byWidgetPredicate(
          (w) => w is Focus && w.focusNode != null && w.focusNode!.hasFocus,
        ),
      );
      final badge = tester.getRect(_badge);
      // On the badge's own ring, halfway down its start edge, and on the
      // tile's, away from the badge.
      final onTheBadgeRing = Offset(badge.left + 1, badge.center.dy);
      final onTheTileRing = Offset(tile.left + 1, tile.top + 30);
      expect(
        pixel(await paint(tester), onTheBadgeRing.dx, onTheBadgeRing.dy),
        isNot(primary),
      );

      // The tile first, then the badge.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(focused, findsOneWidget);
      expect(badgeFocused, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(badgeFocused, findsOneWidget);
      final keyed = await paint(tester);
      expect(pixel(keyed, onTheBadgeRing.dx, onTheBadgeRing.dy), primary);
      expect(
        pixel(keyed, onTheTileRing.dx, onTheTileRing.dy),
        isNot(primary),
        reason: "the ring is the badge's own, not the tile's",
      );

      // A fresh page, and a mouse's click on the badge.
      await tester.pumpWidget(const SizedBox());
      await showTile(tester, expansions: _expansions());
      await click(tester, await connectMouse(tester), badge.center);

      expect(badgeFocused, findsOneWidget);
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      expect(
        pixel(await paint(tester), onTheBadgeRing.dx, onTheBadgeRing.dy),
        isNot(primary),
      );

      // The next key press brings the ring back, where focus already is.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(badgeFocused, findsOneWidget);
      expect(
        pixel(await paint(tester), onTheBadgeRing.dx, onTheBadgeRing.dy),
        primary,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    group('when the badge goes while it holds focus (#711)', () {
      /// The tile with [expansions], and a button after it, so that focus
      /// can come to the badge from somewhere other than the cover.
      Future<Rect> showWithButton(
        WidgetTester tester,
        BgeCoverExpansions? expansions,
      ) async {
        await tester.pumpWidget(
          hostAtSize(
            tester,
            RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      BgeCoverTile(
                        label: 'Azul',
                        onTap: () {},
                        expansions: expansions,
                      ),
                      TextButton(onPressed: () {}, child: const Text('After')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(find.byType(BgeCoverTile));
      }

      /// The primary focus, if it is inside [finder].
      Finder focusedIn(Finder finder) => find.descendant(
        of: finder,
        matching: find.byElementPredicate(
          (e) => identical(e, FocusManager.instance.primaryFocus?.context),
        ),
      );

      testWidgets('the cover takes it, ringed after the keyboard', (
        tester,
      ) async {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
        final tile = await showWithButton(tester, _expansions());
        final onTheRing = Offset(tile.left + 1, tile.top + 30);
        // On to the button after the tile, then back to the badge, so the
        // focus before the badge's was the button's.
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        }
        await tester.pumpAndSettle();
        expect(focusedIn(find.byType(TextButton)), findsOneWidget);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(focusedIn(_badge), findsOneWidget);

        await showWithButton(tester, null);

        expect(_badge, findsNothing);
        expect(focusedIn(find.byType(BgeCoverTile)), findsOneWidget);
        expect(pixel(await paint(tester), onTheRing.dx, onTheRing.dy), primary);
      });

      testWidgets('the cover takes it, unringed after a click', (tester) async {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
        final tile = await showWithButton(tester, _expansions());
        final onTheRing = Offset(tile.left + 1, tile.top + 30);
        await click(
          tester,
          await connectMouse(tester),
          tester.getCenter(_badge),
        );
        expect(focusedIn(_badge), findsOneWidget);

        await showWithButton(tester, null);

        expect(focusedIn(find.byType(BgeCoverTile)), findsOneWidget);
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect(
          pixel(await paint(tester), onTheRing.dx, onTheRing.dy),
          isNot(primary),
          reason: 'the click on the badge was a click on the tile',
        );

        // Until the next key press.
        await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();

        expect(pixel(await paint(tester), onTheRing.dx, onTheRing.dy), primary);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    });
  });

  group('expansions and a missing part (#711)', () {
    testWidgets('the badge is a button named with its count and state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        for (final expanded in [false, true]) {
          await tester.pumpWidget(
            _host(
              tester,
              BgeCoverTile(
                label: 'Azul',
                onTap: () {},
                expansions: _expansions(expanded: expanded),
              ),
            ),
          );

          final badge = tester.getSemantics(_badge);
          expect(
            badge,
            isSemantics(
              label: 'Azul expansions, 2',
              isButton: true,
              hasExpandedState: true,
              isExpanded: expanded,
              hasTapAction: true,
              isFocusable: true,
            ),
            reason: 'expanded: $expanded',
          );
          expect(badge.childrenCount, 0);
          // A node of its own, outside the tile's, which keeps its label.
          final tile = _tileNode(tester);
          expect(tile.id, isNot(badge.id));
          expect(
            tile.getSemanticsData().label,
            'Azul',
            reason: "the badge's words aren't merged into the tile",
          );
          // The drawn count isn't read a second time.
          expect(find.bySemanticsLabel('2'), findsNothing);
          // After the tile, as a screen reader moves.
          final order = [
            for (final node
                in tester.semantics.simulatedAccessibilityTraversal())
              node.id,
          ];
          expect(order, containsAllInOrder([tile.id, badge.id]));
        }
      } finally {
        handle.dispose();
      }
    });

    testWidgets('a tap on the badge toggles, and a tap on the cover still '
        'opens', (tester) async {
      var toggles = 0;
      var opens = 0;
      await tester.pumpWidget(
        _host(
          tester,
          BgeCoverTile(
            label: 'Azul',
            onTap: () => opens++,
            expansions: _expansions(onToggle: () => toggles++),
          ),
        ),
      );

      await tester.tap(_badge);
      expect((toggles, opens), (1, 0));

      await tester.tapAt(tester.getCenter(find.byType(BgeCoverTile)));
      expect((toggles, opens), (1, 1));
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('the whole of the badge takes presses, its corners included '
          '($scale text)', (tester) async {
        var toggles = 0;
        var opens = 0;
        await tester.pumpWidget(
          _host(
            tester,
            BgeCoverTile(
              label: 'Azul',
              onTap: () => opens++,
              expansions: _expansions(onToggle: () => toggles++),
            ),
            textScale: scale,
          ),
        );

        // 1dp in from each corner of the drawn badge, where its rounding
        // leaves the cover showing.
        final badge = tester.getRect(
          find.descendant(of: _badge, matching: find.byType(InkWell)),
        );
        for (final (corner, at) in [
          ('top start', badge.topLeft + const Offset(1, 1)),
          ('top end', badge.topRight + const Offset(-1, 1)),
          ('bottom start', badge.bottomLeft + const Offset(1, -1)),
          ('bottom end', badge.bottomRight + const Offset(-1, -1)),
        ]) {
          final before = toggles;
          await tester.tapAt(at);
          await tester.pump();

          expect((toggles - before, opens), (1, 0), reason: corner);
        }
      });
    }

    testWidgets('the cover offers Show expansions, then Hide expansions, as '
        'a custom action', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        var toggles = 0;
        for (final (expanded, action) in [
          (false, 'Show expansions'),
          (true, 'Hide expansions'),
        ]) {
          await tester.pumpWidget(
            _host(
              tester,
              BgeCoverTile(
                label: 'Azul',
                onTap: () {},
                expansions: _expansions(
                  expanded: expanded,
                  onToggle: () => toggles++,
                ),
              ),
            ),
          );

          final tile = _tileNode(tester);
          expect(
            tile,
            isSemantics(
              label: 'Azul',
              customActions: [CustomSemanticsAction(label: action)],
            ),
          );
          final before = toggles;
          _performCustomAction(tile, action);
          expect(toggles, before + 1, reason: action);
        }
      } finally {
        handle.dispose();
      }
    });

    testWidgets('the badge meets the tap target guidelines at 320dp and 2.0 '
        'text', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        // Two columns, as the Games and Collection grids lay their covers
        // out on a phone, with a long count and a stacked cover.
        const counts = [2, 12, 3, 1];
        await tester.pumpWidget(
          hostAtSize(
            tester,
            Builder(
              builder: (context) => BgePage.slivers(
                title: const Text('Games'),
                width: BgePageWidth.pane,
                semanticChildCount: counts.length,
                slivers: [
                  BgeKeyedSliverGrid<(int, int)>(
                    items: [...counts.indexed],
                    keyOf: (item) => ValueKey(item.$1),
                    gridDelegate: bgeCoverGridDelegate(context),
                    itemBuilder: (context, item) => BgeCoverTile(
                      label: 'Game ${item.$1}',
                      extent: null,
                      stackCount: item.$1 == 2 ? 3 : null,
                      onTap: () {},
                      expansions: _expansions(count: item.$2),
                    ),
                  ),
                ],
              ),
            ),
            size: const Size(320, 640),
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          MediaQuery.textScalerOf(tester.element(_badge.first)).scale(10),
          20,
          reason: 'the text scale reaches the badge',
        );

        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
        const tokens = BgeTokens.standard;
        for (final (index, _) in counts.indexed) {
          final tile = tester.getRect(find.byKey(ValueKey(index)));
          final target = tester.getRect(
            find.descendant(
              of: find.descendant(
                of: find.byKey(ValueKey(index)),
                matching: _badge,
              ),
              matching: find.byType(InkWell),
            ),
          );
          expect(target.width, greaterThanOrEqualTo(tokens.minTapTarget));
          expect(target.height, greaterThanOrEqualTo(tokens.minTapTarget));
          expect(tile.intersect(target), target, reason: 'inside its tile');
        }
      } finally {
        handle.dispose();
      }
    });

    testWidgets('the badge is unlike the stack marker', (tester) async {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        _host(
          tester,
          RepaintBoundary(
            key: boundary,
            child: BgeCoverTile(
              label: 'Azul, 3 copies',
              stackCount: 3,
              onTap: () {},
              expansions: _expansions(),
            ),
          ),
        ),
      );

      final stack = find.byKey(BgeStackMarker.badgeKey);
      expect(stack, findsOneWidget);
      expect(_badge, findsOneWidget);
      expect(
        find.descendant(of: _badge, matching: stack),
        findsNothing,
        reason: 'two badges, not one inside the other',
      );
      expect(find.descendant(of: stack, matching: _badge), findsNothing);

      // Opposite corners: the stack's at the top end, the expansions' at the
      // bottom end.
      final tile = tester.getRect(find.byType(BgeCoverTile));
      final stackRect = tester.getRect(stack);
      final badgeRect = tester.getRect(_badge);
      expect(stackRect.center.dy, lessThan(tile.center.dy));
      expect(badgeRect.center.dy, greaterThan(tile.center.dy));
      expect(stackRect.center.dx, greaterThan(tile.center.dx));
      expect(badgeRect.center.dx, greaterThan(tile.center.dx));

      // In different colours: each badge's fill, beside its content.
      final scheme = BgeTheme.light().colorScheme;
      final ink = tester.getRect(
        find.descendant(of: _badge, matching: find.byType(InkWell)),
      );
      final stackFill = await _colourAt(
        tester,
        boundary,
        Offset(stackRect.left + 2, stackRect.center.dy),
      );
      final badgeFill = await _colourAt(
        tester,
        boundary,
        Offset(ink.center.dx, ink.top + 2),
      );
      expect(stackFill, scheme.secondary);
      expect(badgeFill, scheme.tertiaryContainer);
      expect(stackFill, isNot(badgeFill));
    });

    testWidgets('a marked cover draws its outline and icon, and adds nothing '
        'to the semantics', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final boundary = GlobalKey();
        var opens = 0;
        final tertiary = BgeTheme.light().colorScheme.tertiary;
        Future<(Rect, SemanticsData)> show({required bool marked}) async {
          await tester.pumpWidget(
            _host(
              tester,
              RepaintBoundary(
                key: boundary,
                child: BgeCoverTile(
                  label: 'Azul, base game not on this server',
                  onTap: () => opens++,
                  marked: marked,
                ),
              ),
            ),
          );
          final tile = _tileNode(tester);
          expect(tile.childrenCount, 0);
          return (
            tester.getRect(find.byType(BgeCoverTile)),
            tile.getSemanticsData(),
          );
        }

        final (tile, unmarked) = await show(marked: false);
        // Just inside the cover's start edge, halfway down it.
        final onTheOutline = Offset(tile.left + 1, tile.center.dy);
        expect(find.byKey(BgeCoverTile.markKey), findsNothing);
        expect(
          await _colourAt(tester, boundary, onTheOutline),
          isNot(tertiary),
        );

        final (_, marked) = await show(marked: true);

        expect(await _colourAt(tester, boundary, onTheOutline), tertiary);
        final icon = find.descendant(
          of: find.byKey(BgeCoverTile.markKey),
          matching: find.byIcon(Icons.link_off),
        );
        expect(icon, findsOneWidget);
        final iconCentre = tester.getCenter(icon);
        expect(iconCentre.dx, lessThan(tile.center.dx), reason: 'at the start');
        expect(iconCentre.dy, lessThan(tile.center.dy), reason: 'at the top');
        expect(marked, unmarked, reason: 'the label carries the words');

        // The mark takes no press of its own.
        await tester.tapAt(iconCentre);
        expect(opens, 1);
      } finally {
        handle.dispose();
      }
    });

    testWidgets('the tile keeps its focus and its node as a badge comes and '
        'goes', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        Future<void> show(BgeCoverExpansions? expansions) => tester.pumpWidget(
          _host(
            tester,
            BgeCoverTile(label: 'Azul', onTap: () {}, expansions: expansions),
          ),
        );
        await show(null);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final focus = FocusManager.instance.primaryFocus;
        expect(_tileNode(tester), isSemantics(label: 'Azul', isFocused: true));
        final node = _tileNode(tester).id;

        for (final expansions in [_expansions(), null]) {
          await show(expansions);
          await tester.pumpAndSettle();

          final step = expansions == null ? 'badge gone' : 'badge arrived';
          expect(FocusManager.instance.primaryFocus, focus, reason: step);
          expect(_tileNode(tester).id, node, reason: step);
        }
      } finally {
        handle.dispose();
      }
    });
  });
}
