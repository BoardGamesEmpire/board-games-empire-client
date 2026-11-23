import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

/// What a pop-up changes about a pinned footer. The rules a page's footer is
/// held to, the cap and the room kept for one that gets shorter, are tested
/// through `BgePage`, in `bge_page_test.dart`: these are the options the
/// catalog's quick look takes (#1037).
void main() {
  const bandKey = Key('band');
  const actionKey = Key('action');
  const lastRowKey = Key('last row');
  const insets = EdgeInsets.symmetric(horizontal: 16, vertical: 8);

  /// The body's own scroll view.
  final body = find.byType(Scrollable).first;

  ScrollPosition bodyOf(WidgetTester tester) =>
      tester.state<ScrollableState>(body).position;

  /// A body of [rows] 48dp rows over a footer as tall as [height] says, in
  /// a 400x600 window, at the foot of it as a sheet is. A footer of no
  /// height draws nothing.
  Future<void> pump(
    WidgetTester tester,
    ValueNotifier<double> height, {
    int rows = 40,
    bool shrinkWrap = true,
    EdgeInsets footerPadding = EdgeInsets.zero,
    bool emptiedFooterKeepsRoom = true,
  }) async {
    addTearDown(height.dispose);
    await tester.pumpWidget(
      hostAtSize(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: BgePinnedFooter(
              shrinkWrap: shrinkWrap,
              footerKey: bandKey,
              footerPadding: footerPadding,
              emptiedFooterKeepsRoom: emptiedFooterKeepsRoom,
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var n = 0; n < rows; n++)
                      SizedBox(
                        key: n == rows - 1 ? lastRowKey : null,
                        height: 48,
                        child: Text('row $n'),
                      ),
                  ],
                ),
              ),
              footer: ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (context, value, _) => value == 0
                    ? const SizedBox.shrink()
                    : SizedBox(key: actionKey, height: value),
              ),
            ),
          ),
        ),
        size: const Size(400, 600),
      ),
    );
  }

  Future<void> scrollToEnd(WidgetTester tester) async {
    final position = bodyOf(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
  }

  group('shrinkWrap', () {
    testWidgets('takes only the height a short body and its footer need', (
      tester,
    ) async {
      await pump(tester, ValueNotifier(40), rows: 2);

      expect(tester.getSize(find.byType(BgePinnedFooter)).height, 96 + 40);
      expect(tester.getSize(body).height, 96);
      // Under the body, at the foot of the window.
      expect(tester.getRect(find.byKey(bandKey)).top, 600 - 40);
      expect(tester.getRect(find.byKey(bandKey)).bottom, 600);
    });

    testWidgets('without it, the pair fill the height on offer', (
      tester,
    ) async {
      await pump(tester, ValueNotifier(40), rows: 2, shrinkWrap: false);

      expect(tester.getSize(find.byType(BgePinnedFooter)).height, 600);
      expect(tester.getSize(body).height, 600 - 40);
    });

    testWidgets('a long body scrolls in what the footer leaves', (
      tester,
    ) async {
      await pump(tester, ValueNotifier(40));

      expect(tester.getSize(find.byType(BgePinnedFooter)).height, 600);
      expect(tester.getSize(body).height, 600 - 40);
      expect(bodyOf(tester).maxScrollExtent, 40 * 48 - 560);
    });

    testWidgets('the footer is held to half, and the body keeps half', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: BgePinnedFooter(
                shrinkWrap: true,
                footerKey: bandKey,
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (var n = 0; n < 40; n++)
                        SizedBox(height: 48, child: Text('row $n')),
                    ],
                  ),
                ),
                // Taller than the cap, and scrolling within it.
                footer: const SingleChildScrollView(
                  primary: false,
                  child: SizedBox(height: 1000),
                ),
              ),
            ),
          ),
          size: const Size(400, 600),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(bandKey)).height, 300);
      expect(tester.getSize(body).height, 300);
    });
  });

  group('footerPadding', () {
    testWidgets('insets the footer inside its band', (tester) async {
      await pump(tester, ValueNotifier(40), footerPadding: insets);

      final band = tester.getRect(find.byKey(bandKey));
      final action = tester.getRect(find.byKey(actionKey));
      expect(band.height, 40 + insets.vertical);
      expect(action.top, band.top + insets.top);
      expect(action.bottom, band.bottom - insets.bottom);
      expect(action.left, band.left + insets.left);
      expect(action.right, band.right - insets.right);
      expect(tester.getSize(body).height, 600 - band.height);
    });

    testWidgets('goes with a footer that draws nothing', (tester) async {
      final height = ValueNotifier<double>(0);
      await pump(tester, height, footerPadding: insets);

      expect(tester.getSize(find.byKey(bandKey)).height, 0);
      expect(tester.getSize(body).height, 600);

      height.value = 40;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(bandKey)).height, 40 + insets.vertical);
    });
  });

  group('a footer that gets shorter, at the end of the body', () {
    testWidgets('keeps its room, insets and all, and stays at its foot', (
      tester,
    ) async {
      final height = ValueNotifier<double>(100);
      await pump(
        tester,
        height,
        footerPadding: insets,
        emptiedFooterKeepsRoom: false,
      );
      await scrollToEnd(tester);
      final pixels = bodyOf(tester).pixels;
      final row = tester.getRect(find.byKey(lastRowKey));
      final band = tester.getRect(find.byKey(bandKey));
      expect(band.height, 100 + insets.vertical);

      height.value = 40;
      await tester.pumpAndSettle();

      // No row moves: the band is as tall as it was.
      expect(bodyOf(tester).pixels, pixels);
      expect(tester.getRect(find.byKey(lastRowKey)), row);
      expect(tester.getRect(find.byKey(bandKey)), band);
      // What is left of the footer is at the band's foot, in its insets,
      // with the room above it.
      final action = tester.getRect(find.byKey(actionKey));
      expect(action.height, 40);
      expect(action.bottom, band.bottom - insets.bottom);
      expect(action.left, band.left + insets.left);

      // The room goes as the body leaves its end, at the pace it leaves.
      bodyOf(tester).jumpTo(pixels - 20);
      await tester.pumpAndSettle();
      expect(bodyOf(tester).pixels, pixels - 20);
      expect(tester.getSize(find.byKey(bandKey)).height, band.height - 20);

      bodyOf(tester).jumpTo(pixels - 200);
      await tester.pumpAndSettle();
      expect(bodyOf(tester).pixels, pixels - 200);
      expect(tester.getSize(find.byKey(bandKey)).height, 40 + insets.vertical);
    });

    testWidgets('away from the end, it gives its room back at once', (
      tester,
    ) async {
      final height = ValueNotifier<double>(100);
      await pump(tester, height, footerPadding: insets);
      bodyOf(tester).jumpTo(300);
      await tester.pumpAndSettle();

      height.value = 40;
      await tester.pumpAndSettle();

      expect(bodyOf(tester).pixels, 300);
      expect(tester.getSize(find.byKey(bandKey)).height, 40 + insets.vertical);
    });
  });

  group('a footer that comes to draw nothing, at the end of the body', () {
    testWidgets('keeps its room by default, as one that got shorter does', (
      tester,
    ) async {
      final height = ValueNotifier<double>(100);
      await pump(tester, height, footerPadding: insets);
      await scrollToEnd(tester);
      final pixels = bodyOf(tester).pixels;
      final row = tester.getRect(find.byKey(lastRowKey));
      final band = tester.getRect(find.byKey(bandKey));

      height.value = 0;
      await tester.pumpAndSettle();

      expect(find.byKey(actionKey), findsNothing);
      expect(bodyOf(tester).pixels, pixels);
      expect(tester.getRect(find.byKey(lastRowKey)), row);
      expect(tester.getRect(find.byKey(bandKey)), band);
    });

    testWidgets('with emptiedFooterKeepsRoom false, gives it all back at '
        'once', (tester) async {
      final height = ValueNotifier<double>(100);
      await pump(
        tester,
        height,
        footerPadding: insets,
        emptiedFooterKeepsRoom: false,
      );
      await scrollToEnd(tester);
      final pixels = bodyOf(tester).pixels;
      final band = tester.getSize(find.byKey(bandKey)).height;

      height.value = 0;
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byKey(bandKey)).height, 0);
      expect(tester.getSize(body).height, 600);
      // The body, taller by what the footer gave back, is at its new end.
      expect(bodyOf(tester).pixels, pixels - band);
      expect(bodyOf(tester).extentAfter, 0);
    });
  });
}
