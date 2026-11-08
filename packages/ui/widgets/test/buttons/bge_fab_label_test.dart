import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// An extended button reading [label], on a page [size] wide at [scale].
Future<void> _pump(
  WidgetTester tester,
  Widget label, {
  required Size size,
  required double scale,
}) async {
  useViewSize(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      theme: BgeTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: const SizedBox.expand(),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () {},
          icon: const Icon(Icons.add),
          label: label,
        ),
      ),
    ),
  );
}

Rect _fab(WidgetTester tester) =>
    tester.getRect(find.byType(FloatingActionButton));

Rect _drawn(WidgetTester tester, Type type) => tester.getRect(
  find.descendant(
    of: find.byType(FloatingActionButton),
    matching: find.byType(type),
  ),
);

void main() {
  const long = 'Add data gateway';

  // The test font draws every glyph one em wide, so this label is wider at
  // 2.0 than any device font makes it: it shows the overflow plainly.
  testWidgets('a plain label pushes the button off a narrow window at 2.0', (
    tester,
  ) async {
    await _pump(tester, const Text(long), size: const Size(320, 800), scale: 2);

    expect(_fab(tester).left, lessThan(0));
  });

  testWidgets('at 2.0 on a narrow window, the button keeps both margins, '
      'and its icon and label are inside it', (tester) async {
    await _pump(
      tester,
      const BgeFabLabel(long),
      size: const Size(320, 800),
      scale: 2,
    );

    final fab = _fab(tester);
    expect(fab.left, moreOrLessEquals(kFloatingActionButtonMargin));
    expect(fab.right, 320 - kFloatingActionButtonMargin);
    expect(_drawn(tester, Icon).left, greaterThanOrEqualTo(fab.left));
    final label = _drawn(tester, FittedBox);
    expect(label.left, greaterThanOrEqualTo(fab.left));
    expect(label.right, lessThanOrEqualTo(fab.right));
    // Scaled down, not cut: the whole line is drawn, smaller.
    expect(find.text(long), findsOneWidget);
    expect(
      tester.getSize(find.byType(FittedBox)).width,
      lessThan(tester.getSize(find.text(long)).width),
    );
  });

  testWidgets('a label with room keeps its size', (tester) async {
    await _pump(
      tester,
      const BgeFabLabel('New event'),
      size: const Size(390, 844),
      scale: 1,
    );

    expect(
      tester.getSize(find.byType(FittedBox)),
      tester.getSize(find.text('New event')),
    );
  });
}
