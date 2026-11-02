import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _longTitle = 'Twilight Imperium: Fourth Edition, Prophecy of Kings';

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
  testWidgets('one node, labelled by the title, with a tap action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(tester, GameCoverTile(title: 'Azul', onTap: () {})),
    );

    final tile = tester.getSemantics(find.byType(GameCoverTile));
    expect(tile, isSemantics(label: 'Azul', hasTapAction: true));
    expect(tile.childrenCount, 0);
    // The picture and the title are the same node.
    expect(tester.getSemantics(find.byType(BgeThumbnail)).id, tile.id);
    expect(tester.getSemantics(find.text('Azul')).id, tile.id);
    handle.dispose();
  });

  testWidgets('a tap calls onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(tester, GameCoverTile(title: 'Azul', onTap: () => taps++)),
    );

    await tester.tap(find.byType(GameCoverTile));

    expect(taps, 1);
  });

  testWidgets('without onTap it offers nothing to press', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(tester, const GameCoverTile(title: 'Azul')));

    expect(
      tester.getSemantics(find.byType(GameCoverTile)),
      isSemantics(label: 'Azul', hasTapAction: false, isFocusable: false),
    );
    handle.dispose();
  });

  testWidgets('a long title at 2.0 is shown whole', (tester) async {
    await tester.pumpWidget(
      _host(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            GameCoverTile(title: 'Azul'),
            GameCoverTile(title: _longTitle),
          ],
        ),
        textScale: 2,
      ),
    );

    final title = find.text(_longTitle);
    expect(tester.takeException(), isNull);
    expect(tester.widget<Text>(title).maxLines, isNull);
    expect(
      tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
      isFalse,
    );
    expect(
      tester.getSize(title).height,
      greaterThan(tester.getSize(find.text('Azul')).height * 2),
      reason: 'it wraps onto more lines rather than being cut to one',
    );
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('the tile and its image grow with the text scale ($scale)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(tester, const GameCoverTile(title: 'Azul'), textScale: scale),
      );

      final width = TextScaler.linear(scale).scale(GameCoverTile.coverExtent);
      expect(tester.getSize(find.byType(GameCoverTile)).width, width);
      expect(tester.getSize(find.byType(BgeThumbnail)), Size.square(width));
    });
  }

  group('what a keyboard or a pointer shows', () {
    final boundary = GlobalKey();

    /// The tile at the top left of the page, drawn through [boundary] so that
    /// a test can read the pixels the user would see.
    Future<Rect> showTile(WidgetTester tester) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: GameCoverTile(title: 'Azul', onTap: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getRect(find.byType(GameCoverTile));
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

    testWidgets('hovering tints the cover, not only the title', (tester) async {
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
  });
}
