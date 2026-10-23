import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

void main() {
  late int uncovered;

  setUp(() => uncovered = 0);

  Future<NavigatorState> pumpScreen(WidgetTester tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ReadAgainWhenUncovered(
          onUncovered: () => uncovered++,
          child: const Text('screen'),
        ),
      ),
    );
    return navigator.currentState!;
  }

  testWidgets('says nothing when the screen first shows', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(uncovered, 0);
  });

  testWidgets('says so once when a route covering the screen leaves', (
    tester,
  ) async {
    final navigator = await pumpScreen(tester);

    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const Text('form')),
      ),
    );
    await tester.pumpAndSettle();
    expect(uncovered, 0);

    navigator.pop();
    await tester.pumpAndSettle();

    expect(uncovered, 1);
  });

  testWidgets('a dialog does not cover the screen', (tester) async {
    final navigator = await pumpScreen(tester);

    unawaited(
      showDialog<void>(
        context: navigator.context,
        builder: (_) => const Text('dialog'),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();

    expect(uncovered, 0);
  });
}
