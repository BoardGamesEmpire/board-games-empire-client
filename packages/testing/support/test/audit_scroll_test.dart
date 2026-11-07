import 'dart:async';

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

/// A page with nothing below its fold, under an open dialog whose [rows] 100dp
/// rows scroll inside it, apart from the page.
Future<void> _openDialog(WidgetTester tester, int rows) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: Text('page'))),
    ),
  );
  unawaited(
    showDialog<void>(
      context: tester.element(find.text('page')),
      builder: (_) => AlertDialog(
        scrollable: true,
        content: Column(
          children: [
            for (var i = 0; i < rows; i++)
              SizedBox(height: 100, child: Text('row $i')),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

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

    testWidgets("expectWholePage within checks a pop-up's own scroll, not "
        "the page's", (tester) async {
      useViewSize(tester, const Size(320, 800));
      await _openDialog(tester, 12);
      final dialog = find.byType(AlertDialog);
      // The dialog's scrollable itself, which `within` may find too.
      final dialogScroll = find
          .ancestor(of: find.text('row 0'), matching: find.byType(Scrollable))
          .first;

      // The page fits, and the dialog's rows run past its own fold.
      expectWholePage(tester);
      for (final within in [dialog, dialogScroll]) {
        final failure = await _failureOf(
          () async => expectWholePage(tester, within: within),
        );
        expect(failure?.message, contains('still scrolls'), reason: '$within');
      }

      await useWholePage(tester);

      expectWholePage(tester, within: dialog);
      expectWholePage(tester, within: dialogScroll);
    });

    // A search field above the list, not inside its scroll: the field's own
    // scrollables come first in the tree, and never scroll.
    testWidgets("expectWholePage within skips a text field's scroll above the "
        'list', (tester) async {
      useViewSize(tester, const Size(320, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              key: const ValueKey('sheet'),
              children: [
                const TextField(),
                const TextField(maxLines: 3),
                Expanded(
                  child: ListView(
                    children: [
                      for (var i = 0; i < 12; i++)
                        SizedBox(height: 100, child: Text('row $i')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final failure = await _failureOf(
        () async => expectWholePage(
          tester,
          within: find.byKey(const ValueKey('sheet')),
        ),
      );
      expect(failure?.message, contains('still scrolls'));
    });

    // A horizontal row above the list, outside any text field: the row comes
    // first in the tree and fits, so only the axis keeps it from passing for
    // the page.
    testWidgets('expectWholePage skips a horizontal row above the list', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 800));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: const [Text('chip a'), Text('chip b')],
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (var i = 0; i < 12; i++)
                        SizedBox(height: 100, child: Text('row $i')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final failure = await _failureOf(() async => expectWholePage(tester));
      expect(failure?.message, contains('the page still scrolls'));
    });
  });
}
