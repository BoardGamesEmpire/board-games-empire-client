import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The theme's button focus ring (#644) where the app's own widgets put a
/// button: at the ends of a page's scroll view, and in a button that keeps
/// focus while it can do nothing.
void main() {
  const tokens = BgeTokens.standard;
  const firstKey = Key('first');
  const lastKey = Key('last');

  /// The ring painters under [within].
  List<BgeButtonFocusRingPainter> painters(
    WidgetTester tester,
    Finder within,
  ) => tester
      .widgetList<CustomPaint>(
        find.descendant(of: within, matching: find.byType(CustomPaint)),
      )
      .map((paint) => paint.foregroundPainter)
      .whereType<BgeButtonFocusRingPainter>()
      .toList();

  /// Whether the button under [key] draws its ring now.
  bool ringed(WidgetTester tester, Key key) =>
      painters(tester, find.byKey(key)).single.color != null;

  /// The button's own [Material], whose shape is the button's.
  Rect buttonRect(WidgetTester tester, Key key) => tester.getRect(
    find.descendant(of: find.byKey(key), matching: find.byType(Material)).first,
  );

  Future<void> tab(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }

  bool focusIsIn(Key key) {
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    return focused != null &&
        find
            .ancestor(of: find.byWidget(focused), matching: find.byKey(key))
            .evaluate()
            .isNotEmpty;
  }

  testWidgets('ring at the scroll edge is inside the viewport', (tester) async {
    // The tightest window: 320dp at 2.0 text. A filled button's ring is
    // drawn outside it, so the page's padding has to leave it room at both
    // ends of the scroll, where nothing is past the button but the edge.
    await tester.pumpWidget(
      hostAtSize(
        tester,
        BgePage(
          title: const Text('Page'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: firstKey,
                onPressed: () {},
                child: const Text('First'),
              ),
              for (var i = 0; i < 20; i++) Text('Paragraph $i of the page.'),
              FilledButton(
                key: lastKey,
                onPressed: () {},
                child: const Text('Last'),
              ),
            ],
          ),
        ),
        size: const Size(320, 640),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    final viewport = scrollViewportOf(tester);
    final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
    final reach = tokens.focusOutlineWidth + tokens.focusRingGap;

    void expectRingInside(Key key, String where) {
      expect(ringed(tester, key), isTrue, reason: '$where button is ringed');
      final ring = buttonRect(tester, key).inflate(reach);
      expect(ring.top, greaterThanOrEqualTo(viewportRect.top), reason: where);
      expect(
        ring.bottom,
        lessThanOrEqualTo(viewportRect.bottom),
        reason: where,
      );
      expect(ring.left, greaterThanOrEqualTo(viewportRect.left), reason: where);
      expect(ring.right, lessThanOrEqualTo(viewportRect.right), reason: where);
    }

    // The top of the scroll.
    await tab(tester);
    expect(focusIsIn(firstKey), isTrue);
    expect(pageScrollOf(tester).position.pixels, 0);
    expectRingInside(firstKey, 'first');

    // The end of the scroll.
    final position = pageScrollOf(tester).position;
    expect(position.maxScrollExtent, greaterThan(0), reason: 'it scrolls');
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tab(tester);
    await tester.pumpAndSettle();
    expect(focusIsIn(lastKey), isTrue);
    expect(position.pixels, position.maxScrollExtent);
    expectRingInside(lastKey, 'last');
  });

  // Tab scrolls only the button's own box into view, flush against the
  // viewport's edge, which left the outside ring's last 4dp clipped. The ring
  // scrolls the rest of itself in as it appears (#50).
  for (final scale in [1.0, 2.0]) {
    testWidgets('ring of a button Tab scrolls to mid-page is inside the '
        'viewport, at $scale text', (tester) async {
      const midKey = Key('mid');
      await tester.pumpWidget(
        hostAtSize(
          tester,
          BgePage(
            title: const Text('Page'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 30; i++) Text('Paragraph $i of the page.'),
                FilledButton(
                  key: midKey,
                  onPressed: () {},
                  child: const Text('Mid'),
                ),
                for (var i = 0; i < 30; i++) Text('Paragraph $i of the page.'),
              ],
            ),
          ),
          size: const Size(320, 640),
          textScale: scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(pageScrollOf(tester).position.pixels, 0);

      await tab(tester);
      await tester.pumpAndSettle();
      expect(focusIsIn(midKey), isTrue);
      expect(ringed(tester, midKey), isTrue);
      expect(
        pageScrollOf(tester).position.pixels,
        greaterThan(0),
        reason: 'Tab scrolled to it',
      );
      final viewport = scrollViewportOf(tester);
      final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
      final ring = buttonRect(
        tester,
        midKey,
      ).inflate(tokens.focusOutlineWidth + tokens.focusRingGap);
      expect(ring.bottom, lessThanOrEqualTo(viewportRect.bottom));
      expect(ring.top, greaterThanOrEqualTo(viewportRect.top));
    });
  }

  // A press moves focus but shows no ring, so it scrolls nothing for one.
  testWidgets('a button focused by a touch does not scroll for its ring', (
    tester,
  ) async {
    await tester.pumpWidget(
      hostAtSize(
        tester,
        BgePage(
          title: const Text('Page'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < 4; i++) Text('Paragraph $i of the page.'),
              FilledButton(
                key: firstKey,
                onPressed: () {},
                child: const Text('Tapped'),
              ),
              for (var i = 0; i < 40; i++) Text('Paragraph $i of the page.'),
            ],
          ),
        ),
        size: const Size(320, 640),
      ),
    );
    await tester.pumpAndSettle();
    final position = pageScrollOf(tester).position;
    position.jumpTo(
      tester.getRect(find.byKey(firstKey)).bottom -
          scrollViewportOf(tester).localToGlobal(Offset.zero).dy -
          scrollViewportOf(tester).size.height +
          position.pixels,
    );
    await tester.pumpAndSettle();
    final before = position.pixels;

    Focus.of(tester.element(find.text('Tapped'))).requestFocus();
    await tester.pumpAndSettle();
    expect(ringed(tester, firstKey), isFalse, reason: 'touch mode');
    expect(position.pixels, before);
  });

  // The ring finishes Tab's scroll; it doesn't start one. Focus moved in code
  // to a button the user has scrolled away from leaves the page where it is.
  testWidgets('focus moved in code to a button out of view scrolls nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      hostAtSize(
        tester,
        BgePage(
          title: const Text('Page'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: firstKey,
                onPressed: () {},
                child: const Text('Away'),
              ),
              for (var i = 0; i < 40; i++) Text('Paragraph $i of the page.'),
            ],
          ),
        ),
        size: const Size(320, 640),
      ),
    );
    await tester.pumpAndSettle();
    // The keyboard's highlight mode, so the ring would show.
    await tester.sendKeyEvent(LogicalKeyboardKey.shift);
    final position = pageScrollOf(tester).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final before = position.pixels;

    Focus.of(tester.element(find.text('Away'))).requestFocus();
    await tester.pumpAndSettle();
    expect(ringed(tester, firstKey), isTrue);
    expect(position.pixels, before);
  });

  testWidgets('a busy BgeInertButton keeps its ring; a disabled button has '
      'none', (tester) async {
    const inertKey = Key('inert');
    const disabledKey = Key('disabled');

    Widget page({required bool busy}) => Scaffold(
      body: Column(
        children: [
          BgeInertButton(
            inert: busy,
            label: busy ? 'Saving' : 'Save',
            onPressed: () {},
            builder: (context, focusNode, onPressed) => FilledButton(
              key: inertKey,
              focusNode: focusNode,
              onPressed: onPressed,
              child: Text(busy ? 'Saving' : 'Save'),
            ),
          ),
          const FilledButton(
            key: disabledKey,
            onPressed: null,
            child: Text('Disabled'),
          ),
        ],
      ),
    );

    await tester.pumpWidget(hostAtSize(tester, page(busy: false)));
    await tab(tester);
    expect(focusIsIn(inertKey), isTrue);
    expect(ringed(tester, inertKey), isTrue);

    // Pressed, it goes busy and keeps its focus, so it keeps its ring.
    await tester.pumpWidget(hostAtSize(tester, page(busy: true)));
    await tester.pump();
    expect(focusIsIn(inertKey), isTrue);
    expect(ringed(tester, inertKey), isTrue);

    // A disabled button can't hold focus, so Tab passes it by and it never
    // draws a ring.
    for (var i = 0; i < 3; i++) {
      await tab(tester);
      expect(focusIsIn(disabledKey), isFalse, reason: 'Tab ${i + 1}');
      expect(ringed(tester, disabledKey), isFalse, reason: 'Tab ${i + 1}');
    }
  });
}
