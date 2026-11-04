import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _key = ValueKey('button');

Widget _host({
  required bool inert,
  required VoidCallback onPressed,
  bool? expanded,
  bool ignoreKeyRepeats = true,
}) => MaterialApp(
  theme: BgeTheme.light(),
  home: Scaffold(
    body: Center(
      child: BgeInertButton(
        inert: inert,
        label: inert ? 'Working' : 'Go',
        expanded: expanded,
        ignoreKeyRepeats: ignoreKeyRepeats,
        onPressed: onPressed,
        builder: (context, focusNode, onPressed) => TextButton(
          key: _key,
          focusNode: focusNode,
          onPressed: onPressed,
          child: Text(inert ? 'Working' : 'Go'),
        ),
      ),
    ),
  ),
);

FocusNode _focus(WidgetTester tester) =>
    tester.widget<TextButton>(find.byKey(_key)).focusNode!;

void main() {
  testWidgets('enabled while inert, keeping focus, and a press does nothing', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(_host(inert: false, onPressed: () => presses++));
    _focus(tester).requestFocus();
    await tester.pump();

    await tester.pumpWidget(_host(inert: true, onPressed: () => presses++));
    expect(tester.widget<TextButton>(find.byKey(_key)).enabled, isTrue);
    expect(_focus(tester).hasPrimaryFocus, isTrue);

    await tester.tap(find.byKey(_key));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 0);

    await tester.pumpWidget(_host(inert: false, onPressed: () => presses++));
    await tester.tap(find.byKey(_key));
    expect(presses, 1);
  });

  testWidgets('one semantics node, inert or not; inert, it reads as not '
      'enabled with no tap', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(inert: false, onPressed: () {}));
    final rest = tester.getSemantics(find.byKey(_key));
    expect(
      rest,
      matchesSemantics(
        label: 'Go',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    await tester.pumpWidget(_host(inert: true, onPressed: () {}));
    final inert = tester.getSemantics(find.byKey(_key));
    expect(inert.id, rest.id);
    expect(
      inert,
      matchesSemantics(
        label: 'Working',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('says whether the menu it opens is open', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(inert: false, expanded: true, onPressed: () {}),
    );

    expect(
      tester.getSemantics(find.byKey(_key)),
      matchesSemantics(
        label: 'Go',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasExpandedState: true,
        isExpanded: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a held Enter presses once, even when it outlasts the inert '
      'spell its press began', (tester) async {
    var presses = 0;
    Widget at({required bool inert}) =>
        _host(inert: inert, onPressed: () => presses++);
    await tester.pumpWidget(at(inert: false));
    _focus(tester).requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pumpWidget(at(inert: true));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.pumpWidget(at(inert: false));
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(presses, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(presses, 2);
  });

  testWidgets('with ignoreKeyRepeats false, each repeat presses again', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(
      _host(inert: false, ignoreKeyRepeats: false, onPressed: () => presses++),
    );
    _focus(tester).requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);

    expect(presses, 3);
  });
}
