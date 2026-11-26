import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

void main() {
  final page = find.text('page', skipOffstage: false);

  bool over(WidgetTester tester) => anyRouteOver(tester.element(page));

  group('on one navigator', () {
    Future<NavigatorState> pumpPage(WidgetTester tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Text('page')),
      );
      return navigator.currentState!;
    }

    testWidgets('nothing over the page', (tester) async {
      await pumpPage(tester);

      expect(over(tester), isFalse);
    });

    testWidgets('a dialog over the page, until it closes', (tester) async {
      final navigator = await pumpPage(tester);

      unawaited(
        showDialog<void>(
          context: navigator.context,
          builder: (_) => const Text('dialog'),
        ),
      );
      await tester.pumpAndSettle();
      expect(over(tester), isTrue);

      navigator.pop();
      await tester.pumpAndSettle();
      expect(over(tester), isFalse);
    });

    testWidgets('a page over the page', (tester) async {
      final navigator = await pumpPage(tester);

      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Text('next')),
      );
      await tester.pumpAndSettle();

      expect(over(tester), isTrue);
    });
  });

  group('on a navigator nested in a route of the root one', () {
    final root = GlobalKey<NavigatorState>();
    final nested = GlobalKey<NavigatorState>();

    // As a shell holds its pages: the page is the current route on the
    // nested navigator, which a route of the root navigator holds.
    Future<void> pumpNested(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        navigatorKey: root,
        home: Navigator(
          key: nested,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const Text('page')),
        ),
      ),
    );

    testWidgets('nothing over the page', (tester) async {
      await pumpNested(tester);

      expect(over(tester), isFalse);
    });

    testWidgets('a dialog on the root navigator, which leaves the page '
        'current on its own', (tester) async {
      await pumpNested(tester);

      unawaited(
        showDialog<void>(
          context: root.currentContext!,
          builder: (_) => const Text('dialog'),
        ),
      );
      await tester.pumpAndSettle();

      expect(ModalRoute.isCurrentOf(tester.element(page)), isTrue);
      expect(over(tester), isTrue);

      root.currentState!.pop();
      await tester.pumpAndSettle();
      expect(over(tester), isFalse);
    });

    testWidgets('a page on the nested navigator', (tester) async {
      await pumpNested(tester);

      nested.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('next')),
      );
      await tester.pumpAndSettle();

      expect(over(tester), isTrue);
    });
  });

  testWidgets('a context in no route', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('page'),
      ),
    );

    expect(over(tester), isFalse);
  });
}
