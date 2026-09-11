import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A non-virtualized scrolling column, the shape #209's banner sits in: a
/// form that overflows its viewport. Nothing is recycled, so a widget scrolled
/// out of view stays in the tree — which is the whole point being measured.
Widget _longForm({int count = 10}) => SingleChildScrollView(
  child: Column(
    children: [
      for (var i = 0; i < count; i++)
        SizedBox(height: 100, child: Text('row $i')),
    ],
  ),
);

/// A list long enough to overflow any viewport used here, carrying the
/// `semanticChildCount` that becomes `scrollChildCount` on the scrolling node.
Widget _longList({int count = 40}) => ListView.builder(
  semanticChildCount: count,
  itemCount: count,
  itemBuilder: (_, i) => SizedBox(height: 100, child: Text('row $i')),
);

void main() {
  group('useViewSize', () {
    testWidgets('puts the size on the view, where it constrains layout', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 400));

      expect(tester.view.physicalSize, const Size(320, 400));
      expect(tester.view.devicePixelRatio, 1);

      // The point of setting it on the view rather than in a MediaQuery: the
      // widget actually lays out against it.
      await tester.pumpWidget(
        const MaterialApp(home: SizedBox.expand(child: Text('x'))),
      );
      expect(tester.getSize(find.byType(SizedBox).first).width, 320);
    });

    testWidgets('a suite that never sized the view sees the default — the '
        'teardown from other cases in this file did not leak', (tester) async {
      // `tester.view` lives on the singleton binding and is NOT restored by
      // `TestWidgetsFlutterBinding.reset()`, so a missing teardown leaks into
      // every later test. Ordering is randomized, so this is a guard rather
      // than a proof; the deterministic half is that `useViewSize` owns the
      // teardown, so no call site can forget it.
      expect(tester.view.physicalSize, tester.view.display.size);
    });
  });

  group('hostAtSize', () {
    testWidgets('installs BgeTheme, so BgeTokens.of does not fall back', (
      tester,
    ) async {
      late BuildContext captured;
      await tester.pumpWidget(
        hostAtSize(
          tester,
          Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      // The fallback is what #213 exists to make impossible: without a theme,
      // `BgeTokens.of` returns `BgeTokens.standard`, and an assertion written
      // against `BgeTokens.standard` then cannot fail.
      expect(Theme.of(captured).extension<BgeTokens>(), isNotNull);
    });

    testWidgets('applies the text scaler through an effective MediaQuery', (
      tester,
    ) async {
      late BuildContext captured;
      await tester.pumpWidget(
        hostAtSize(
          tester,
          Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
          textScale: 2,
        ),
      );

      expect(MediaQuery.of(captured).textScaler.scale(10), 20);
    });
  });

  group('scrollChildCountOnScrollingNode', () {
    testWidgets('finds the count on the node that actually scrolls', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(hostAtSize(tester, _longList()));

      expect(scrollChildCountOnScrollingNode(tester), 40);
      handle.dispose();
    });

    testWidgets('still finds it when the viewport is scrolled to the END — '
        'the regression a scrollUp-only walk cannot see (#257)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(hostAtSize(tester, _longList()));

      // Scroll to the very end. A vertical viewport offers `scrollUp` only
      // while there is content ahead, so at the end it is gone and only
      // `scrollDown` remains.
      await tester.fling(find.byType(ListView), const Offset(0, -10000), 4000);
      await tester.pumpAndSettle();

      expect(
        scrollChildCountOnScrollingNode(tester),
        40,
        reason: 'the union predicate still matches via scrollDown',
      );

      // And this is the copy that used to live in app_shell: matching
      // `scrollUp` alone reports null here, which is indistinguishable from
      // the count never having been wired at all.
      expect(
        scrollChildCountOnScrollingNode(
          tester,
          scrollActions: const {SemanticsAction.scrollUp},
        ),
        isNull,
        reason: 'pins WHY the union predicate is the correct default',
      );
      handle.dispose();
    });

    testWidgets('returns null when nothing scrolls', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(hostAtSize(tester, const Text('static')));

      expect(scrollChildCountOnScrollingNode(tester), isNull);
      handle.dispose();
    });
  });

  group('scroll geometry', () {
    testWidgets('topInViewport goes NEGATIVE for a widget scrolled past — '
        'the measure findsOneWidget cannot see', (tester) async {
      await tester.pumpWidget(
        hostAtSize(tester, _longForm(), size: const Size(400, 400)),
      );

      final firstRow = find.text('row 0');
      expect(topInViewport(tester, firstRow), 0);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();

      expect(topInViewport(tester, firstRow), lessThan(0));
      expect(
        firstRow,
        findsOneWidget,
        reason: 'still in the tree — which is why a finder cannot catch this',
      );
    });

    testWidgets(
      'scrollViewportOf and pageScrollOf resolve the page scrollable',
      (tester) async {
        await tester.pumpWidget(
          hostAtSize(tester, _longForm(), size: const Size(400, 400)),
        );

        expect(scrollViewportOf(tester).size.height, 400);
        expect(pageScrollOf(tester).position.pixels, 0);
      },
    );
  });
}
