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

      testWidgets('decodes a thumbnail host\'s image as sent', (tester) async {
        expect(
          await decodedSize(tester, width: 264, height: 352),
          const Size(264, 352),
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
}
