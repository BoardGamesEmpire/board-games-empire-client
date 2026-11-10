import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(WidgetTester tester, Widget child, {double textScale = 1}) =>
    hostAtSize(
      tester,
      Scaffold(
        body: Align(alignment: Alignment.topLeft, child: child),
      ),
      size: const Size(600, 800),
      textScale: textScale,
    );

/// The marker's card layers, found by their fill.
Finder _layers(WidgetTester tester) {
  final fill = Theme.of(tester.element(find.byType(BgeStackMarker)))
      .colorScheme
      .surfaceContainerHighest;
  return find.descendant(
    of: find.byType(BgeStackMarker),
    matching: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == fill,
    ),
  );
}

void main() {
  testWidgets('shows the count and two layers behind the child', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        tester,
        const BgeStackMarker(
          count: 3,
          child: SizedBox.square(key: Key('child'), dimension: 56),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(BgeStackMarker.badgeKey),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    final scheme = Theme.of(tester.element(find.byType(BgeStackMarker)))
        .colorScheme;
    final layerBoxes = _layers(tester)
        .evaluate()
        .map((e) => e.widget as DecoratedBox)
        .toList();
    expect(layerBoxes, hasLength(2));
    for (final b in layerBoxes) {
      final d = b.decoration as BoxDecoration;
      expect((d.border! as Border).top.color, scheme.outline);
    }
    // Behind the child in paint order: they come before it in the tree.
    final order = find
        .descendant(
          of: find.byType(BgeStackMarker),
          matching: find.byWidgetPredicate(
            (w) =>
                w.key == const Key('child') ||
                (w is DecoratedBox &&
                    w.decoration is BoxDecoration &&
                    (w.decoration as BoxDecoration).color ==
                        scheme.surfaceContainerHighest),
          ),
        )
        .evaluate()
        .map((e) => e.widget.key == const Key('child'))
        .toList();
    expect(order, [false, false, true]);
  });

  testWidgets('adds no semantics of its own', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        tester,
        BgeStackMarker(
          count: 3,
          child: Semantics(
            label: 'Azul',
            child: const SizedBox.square(dimension: 56),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('3'), findsNothing);
    expect(find.bySemanticsLabel('Azul'), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel('Azul')).label, 'Azul');
    handle.dispose();
  });

  testWidgets("the layers stay inside the marker's box", (tester) async {
    await tester.pumpWidget(
      _host(
        tester,
        const BgeStackMarker(count: 12, child: SizedBox.square(dimension: 56)),
        textScale: 2,
      ),
    );

    final box = tester.getRect(find.byType(BgeStackMarker));
    final tokens = BgeTokens.of(tester.element(find.byType(BgeStackMarker)));
    expect(box.width, 56 + 2 * tokens.spaceXs);
    expect(box.height, 56 + 2 * tokens.spaceXs);
    for (final e in _layers(tester).evaluate()) {
      final r = tester.getRect(find.byWidget(e.widget));
      expect(r.left, greaterThanOrEqualTo(box.left));
      expect(r.top, greaterThanOrEqualTo(box.top));
      expect(r.right, lessThanOrEqualTo(box.right));
      expect(r.bottom, lessThanOrEqualTo(box.bottom));
    }
    final badge = tester.getRect(find.byKey(BgeStackMarker.badgeKey));
    expect(badge.top, box.top);
    expect(badge.right, box.right);
  });

  testWidgets('the layers sit one and two steps toward the top and end', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        tester,
        const BgeStackMarker(
          count: 3,
          child: SizedBox.square(key: Key('child'), dimension: 56),
        ),
      ),
    );

    final step = BgeTokens.of(tester.element(find.byType(BgeStackMarker)))
        .spaceXs;
    final child = tester.getRect(find.byKey(const Key('child')));
    final rects = _layers(tester)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .toList();
    expect(rects, hasLength(2));
    final tops = rects.map((r) => child.top - r.top).toList()..sort();
    final ends = rects.map((r) => r.right - child.right).toList()..sort();
    expect(tops, [step, 2 * step]);
    expect(ends, [step, 2 * step]);
    for (final r in rects) {
      // Each shows beyond the child, which is what makes it visible.
      expect(r.top, lessThan(child.top));
      expect(r.right, greaterThan(child.right));
    }
  });

  testWidgets('right to left, the layers step toward the top and the left, '
      'and the badge sits at the top left', (tester) async {
    await tester.pumpWidget(
      _host(
        tester,
        const Directionality(
          textDirection: TextDirection.rtl,
          child: BgeStackMarker(
            count: 3,
            child: SizedBox.square(key: Key('child'), dimension: 56),
          ),
        ),
      ),
    );

    final step = BgeTokens.of(tester.element(find.byType(BgeStackMarker)))
        .spaceXs;
    final box = tester.getRect(find.byType(BgeStackMarker));
    final child = tester.getRect(find.byKey(const Key('child')));
    // The child sits at the bottom and the start, which is the right.
    expect(child.bottom, box.bottom);
    expect(child.right, box.right);
    final rects = _layers(tester)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .toList();
    expect(rects, hasLength(2));
    final tops = rects.map((r) => child.top - r.top).toList()..sort();
    final lefts = rects.map((r) => child.left - r.left).toList()..sort();
    expect(tops, [step, 2 * step]);
    expect(lefts, [step, 2 * step]);
    final badge = tester.getRect(find.byKey(BgeStackMarker.badgeKey));
    expect(badge.top, box.top);
    expect(badge.left, box.left);
  });

  testWidgets('reachOf is how far the marker reaches beyond its child', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        tester,
        const BgeStackMarker(count: 3, child: SizedBox.square(dimension: 56)),
      ),
    );

    final context = tester.element(find.byType(BgeStackMarker));
    final box = tester.getRect(find.byType(BgeStackMarker));
    expect(box.width, 56 + BgeStackMarker.reachOf(context));
    expect(box.height, 56 + BgeStackMarker.reachOf(context));
  });

  testWidgets('the layers and the badge stay inside the marker at 2.0 text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        tester,
        const BgeStackMarker(count: 128, child: SizedBox.square(dimension: 56)),
        textScale: 2,
      ),
    );

    final box = tester.getRect(find.byType(BgeStackMarker));
    final rects = [
      for (final e in _layers(tester).evaluate())
        tester.getRect(find.byWidget(e.widget)),
      tester.getRect(find.byKey(BgeStackMarker.badgeKey)),
    ];
    expect(rects, hasLength(3));
    for (final r in rects) {
      expect(box.expandToInclude(r), box);
    }
  });
}
