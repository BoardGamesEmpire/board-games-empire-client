import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

late BuildContext _pageContext;

Future<void> _pumpPage(
  WidgetTester tester, {
  required FocusNode control,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            _pageContext = context;
            return TextButton(
              focusNode: control,
              onPressed: () {},
              child: const Text('control'),
            );
          },
        ),
      ),
    ),
  );
}

void main() {
  late FocusNode control;

  setUp(() => control = FocusNode(debugLabel: 'control'));
  tearDown(() => control.dispose());

  testWidgets('free when nothing has focus', (tester) async {
    // No route, so no focus scope is there to hold focus.
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          _pageContext = context;
          return const SizedBox();
        },
      ),
    );

    expect(FocusManager.instance.primaryFocus, isNull);
    expect(focusIsFree(_pageContext), isTrue);
  });

  testWidgets('free when focus is on the page scope', (tester) async {
    await _pumpPage(tester, control: control);
    FocusScope.of(_pageContext).requestFocus();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());
    expect(focusIsFree(_pageContext), isTrue);
  });

  testWidgets('not free when a control on the page has focus', (tester) async {
    await _pumpPage(tester, control: control);
    control.requestFocus();
    await tester.pump();

    expect(focusIsFree(_pageContext), isFalse);
  });

  testWidgets('not free when a dialog route has focus', (tester) async {
    await _pumpPage(tester, control: control);
    showDialog<void>(
      context: _pageContext,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());
    expect(focusIsFree(_pageContext), isFalse);
  });

  testWidgets('free when focus is still on untouched', (tester) async {
    await _pumpPage(tester, control: control);
    control.requestFocus();
    await tester.pump();

    expect(focusIsFree(_pageContext), isFalse);
    expect(focusIsFree(_pageContext, untouched: control), isTrue);
  });
}
