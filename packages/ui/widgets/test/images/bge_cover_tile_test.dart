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
    Future<(int, ByteData)> paint(WidgetTester tester) async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await render.toImage();
        return (image.width, (await image.toByteData())!);
      }))!;
    }

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

    testWidgets('the ring goes when focus is only a pointer\'s', (
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
  });
}
