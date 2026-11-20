import 'package:bge_test_support/images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _placeholderKey = Key('thumbnail.placeholder');

Widget _host(Widget thumbnail) => MaterialApp(
  theme: BgeTheme.light(),
  home: Scaffold(body: Center(child: thumbnail)),
);

void main() {
  group('BgeThumbnail', () {
    testWidgets('without a URL, shows the placeholder at its size', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const BgeThumbnail(
            extent: 40,
            placeholderIcon: Icons.casino_outlined,
            placeholderKey: _placeholderKey,
          ),
        ),
      );

      expect(find.byKey(_placeholderKey), findsOneWidget);
      expect(find.byIcon(Icons.casino_outlined), findsOneWidget);
      expect(tester.getSize(find.byType(BgeThumbnail)), const Size.square(40));
    });

    testWidgets('a URL that fails shows the placeholder, not an error', (
      tester,
    ) async {
      // The test binding answers every image request with an error.
      await tester.pumpWidget(
        _host(
          const BgeThumbnail(
            url: 'https://example.com/missing.png',
            placeholderKey: _placeholderKey,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(_placeholderKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    group('decoding', () {
      /// Serves a [width] x [height] PNG, shows a 100-pixel thumbnail of it
      /// at a device pixel ratio of 2, and returns the size it decoded at.
      Future<Size> decodedSize(
        WidgetTester tester, {
        required int width,
        required int height,
      }) async {
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetDevicePixelRatio);
        final png = (await tester.runAsync(() => solidPng(width, height)))!;

        return servingImages(png, () async {
          await tester.pumpWidget(
            _host(
              const BgeThumbnail(url: 'https://example.com/a.png', extent: 100),
            ),
          );
          return pumpUntilDecoded(tester, find.byType(BgeThumbnail));
        });
      }

      testWidgets('holds a full-size image to twice the size it is drawn '
          'at, keeping its shape', (tester) async {
        // 100 logical pixels at 2x: drawn at 200, decoded within 400.
        expect(
          await decodedSize(tester, width: 2000, height: 1000),
          const Size(400, 200),
        );
      });

      testWidgets("decodes a thumbnail host's image as sent", (tester) async {
        expect(
          await decodedSize(tester, width: 264, height: 352),
          const Size(264, 352),
        );
      });
    });

    group('cropping', () {
      /// Serves a [width] x [height] PNG and shows a thumbnail of it.
      Future<void> showImage(
        WidgetTester tester, {
        required int width,
        required int height,
        required double extent,
        bool whole = false,
        TextDirection? textDirection,
      }) async {
        final png = (await tester.runAsync(() => solidPng(width, height)))!;
        await servingImages(png, () async {
          final thumbnail = BgeThumbnail(
            url: 'https://example.com/a.png',
            extent: extent,
            whole: whole,
          );
          await tester.pumpWidget(
            _host(
              textDirection == null
                  ? thumbnail
                  : Directionality(
                      textDirection: textDirection,
                      child: thumbnail,
                    ),
            ),
          );
          await pumpUntilDecoded(tester, find.byType(BgeThumbnail));
        });
      }

      testWidgets('crops a portrait image from the top', (tester) async {
        await showImage(tester, width: 100, height: 200, extent: 100);

        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.fit, BoxFit.cover);
        expect(raw.alignment, Alignment.topCenter);
      });

      testWidgets('whole, draws a portrait image uncropped', (tester) async {
        await showImage(
          tester,
          width: 100,
          height: 200,
          extent: 100,
          whole: true,
        );

        expect(tester.getSize(find.byType(RawImage)), const Size(50, 100));
        expect(
          tester.getSize(find.byType(BgeThumbnail)),
          const Size.square(100),
        );
      });

      testWidgets('whole, anchors a portrait image at the start edge', (
        tester,
      ) async {
        await showImage(
          tester,
          width: 100,
          height: 200,
          extent: 100,
          whole: true,
        );

        expect(
          tester.getTopLeft(find.byType(RawImage)),
          tester.getTopLeft(find.byType(BgeThumbnail)),
        );
      });

      testWidgets('whole, anchors a portrait image at the start edge in RTL', (
        tester,
      ) async {
        await showImage(
          tester,
          width: 100,
          height: 200,
          extent: 100,
          whole: true,
          textDirection: TextDirection.rtl,
        );

        expect(
          tester.getTopRight(find.byType(RawImage)),
          tester.getTopRight(find.byType(BgeThumbnail)),
        );
      });

      testWidgets('whole, anchors a landscape image at the top', (
        tester,
      ) async {
        await showImage(
          tester,
          width: 300,
          height: 100,
          extent: 150,
          whole: true,
        );

        expect(tester.getSize(find.byType(RawImage)), const Size(150, 50));
        expect(
          tester.getTopLeft(find.byType(RawImage)),
          tester.getTopLeft(find.byType(BgeThumbnail)),
        );
      });

      testWidgets('whole, the placeholder still fills the square', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            const BgeThumbnail(
              extent: 100,
              whole: true,
              placeholderKey: _placeholderKey,
            ),
          ),
        );
        expect(
          tester.getSize(find.byKey(_placeholderKey)),
          const Size.square(100),
        );

        await tester.pumpWidget(
          _host(
            const BgeThumbnail(
              url: 'https://example.com/missing.png',
              extent: 100,
              whole: true,
              placeholderKey: _placeholderKey,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(_placeholderKey)),
          const Size.square(100),
        );
      });
    });

    testWidgets('says nothing to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const BgeThumbnail(url: 'https://example.com/a.png')),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(RegExp('.')), findsNothing);
      handle.dispose();
    });
  });

  group('BgeThumbnail.titleAlignmentOf', () {
    Future<ListTileTitleAlignment> alignmentAt(
      WidgetTester tester,
      double scale,
    ) async {
      late ListTileTitleAlignment result;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              result = BgeThumbnail.titleAlignmentOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return result;
    }

    testWidgets('is top at the default text size', (tester) async {
      expect(await alignmentAt(tester, 1), ListTileTitleAlignment.top);
    });

    testWidgets('is top just below the threshold', (tester) async {
      expect(
        await alignmentAt(tester, BgeThumbnail.titleHeightTextScale - 0.05),
        ListTileTitleAlignment.top,
      );
    });

    testWidgets('is titleHeight at the threshold', (tester) async {
      expect(
        await alignmentAt(tester, BgeThumbnail.titleHeightTextScale),
        ListTileTitleAlignment.titleHeight,
      );
    });

    testWidgets('is titleHeight at 200%', (tester) async {
      expect(await alignmentAt(tester, 2), ListTileTitleAlignment.titleHeight);
    });

    testWidgets('a short row is over 72dp tall from the threshold', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _scaledList(BgeThumbnail.titleHeightTextScale, [_shortTile]),
      );

      final height = tester.getSize(find.byType(ListTile)).height;
      expect(height, greaterThan(72));
    });

    for (final (scale, width, expected) in [
      (1.0, 390.0, 8.0),
      (BgeThumbnail.titleHeightTextScale, 390.0, 16.0),
      (2.0, 320.0, 16.0),
    ]) {
      testWidgets('short and long rows share a thumbnail top of $expected at '
          '$scale', (tester) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_scaledList(scale, [_shortTile, _longTile]));

        final tops = <double>[];
        for (final tile in find.byType(ListTile).evaluate()) {
          final tileTop = tester.getTopLeft(find.byWidget(tile.widget)).dy;
          final thumb = find.descendant(
            of: find.byWidget(tile.widget),
            matching: find.byType(BgeThumbnail),
          );
          tops.add(tester.getTopLeft(thumb).dy - tileTop);
        }
        expect(tops, [expected, expected]);
      });
    }
  });
}

Widget _scaledList(double scale, List<Widget Function(BuildContext)> tiles) =>
    MaterialApp(
      theme: BgeTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          children: [for (final tile in tiles) Builder(builder: tile)],
        ),
      ),
    );

Widget _shortTile(BuildContext context) => ListTile(
  titleAlignment: BgeThumbnail.titleAlignmentOf(context),
  leading: const BgeThumbnail(),
  title: const Text('Wingspan'),
  subtitle: const Text('1-5 players'),
);

Widget _longTile(BuildContext context) => ListTile(
  titleAlignment: BgeThumbnail.titleAlignmentOf(context),
  leading: const BgeThumbnail(),
  title: const Text(
    'Twilight Imperium Fourth Edition Prophecy of Kings Expanded Saga '
    'Of Many Words',
  ),
  subtitle: const Text('3-6 players'),
);
