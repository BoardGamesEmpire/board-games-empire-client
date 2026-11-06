import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The failure [body] throws, or null.
Future<TestFailure?> _failureOf(Future<void> Function() body) async {
  try {
    await body();
  } on TestFailure catch (e) {
    return e;
  }
  return null;
}

/// A page of [rows] 100dp rows, built lazily, ending in a row named "last".
Widget _page(int rows) => MaterialApp(
  home: Scaffold(
    body: ListView.builder(
      itemCount: rows,
      itemBuilder: (_, i) =>
          SizedBox(height: 100, child: Text(i == rows - 1 ? 'last' : 'row $i')),
    ),
  ),
);

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  group('scrollPageToEnd', () {
    testWidgets('scrolls the page to its end at 320dp', (tester) async {
      useViewSize(tester, const Size(320, 800));
      await tester.pumpWidget(_page(12));

      await scrollPageToEnd(tester);

      expect(_position(tester).pixels, greaterThan(0));
      expect(_position(tester).pixels, _position(tester).maxScrollExtent);
    });

    testWidgets('leaves a wider page at its top', (tester) async {
      useViewSize(tester, const Size(390, 844));
      await tester.pumpWidget(_page(12));

      await scrollPageToEnd(tester);

      expect(_position(tester).pixels, 0);
    });

    testWidgets('fails when the page has nothing below the fold', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 800));
      await tester.pumpWidget(_page(2));

      final failure = await _failureOf(() => scrollPageToEnd(tester));
      expect(failure?.message, contains('nothing to scroll'));
    });
  });

  group('scrollListToEnd', () {
    testWidgets('scrolls a lazy list until its last row is built', (
      tester,
    ) async {
      useViewSize(tester, const Size(390, 844));
      await tester.pumpWidget(_page(60));
      expect(find.text('last'), findsNothing);

      await scrollListToEnd(tester, find.text('last'));

      expect(_position(tester).pixels, _position(tester).maxScrollExtent);
    });

    testWidgets('fails a list that fits, unless mustScroll is false', (
      tester,
    ) async {
      useViewSize(tester, const Size(390, 844));
      await tester.pumpWidget(_page(2));

      final failure = await _failureOf(
        () => scrollListToEnd(tester, find.text('last')),
      );
      expect(failure?.message, contains('nothing to scroll'));

      await scrollListToEnd(tester, find.text('last'), mustScroll: false);
    });
  });

  testWidgets('scrollPageToTop scrolls the page back to its top', (
    tester,
  ) async {
    useViewSize(tester, const Size(390, 844));
    await tester.pumpWidget(_page(12));
    _position(tester).jumpTo(300);
    await tester.pump();

    await scrollPageToTop(tester);

    expect(_position(tester).pixels, 0);
  });

  group('useWholePage', () {
    testWidgets('makes the view tall enough to hold the page, at its width', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 800));
      await tester.pumpWidget(_page(12));
      expect(_position(tester).maxScrollExtent, greaterThan(0));

      await useWholePage(tester);

      expect(tester.view.physicalSize, const Size(320, 6000));
      expectWholePage(tester);
    });

    testWidgets('expectWholePage fails while the page still scrolls', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 800));
      await tester.pumpWidget(_page(12));

      final failure = await _failureOf(() async => expectWholePage(tester));
      expect(failure?.message, contains('the page still scrolls'));
    });
  });
}
