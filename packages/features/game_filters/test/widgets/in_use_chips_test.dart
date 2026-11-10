import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_filters/game_filters.dart';

import '../support/game_filters_app.dart';

// The row of chips by itself, over a value that is no filter: names held as
// one string, "ada,bo,cy". `GameFiltersInUse`'s suite covers it drawing the
// filters; this pins what any other caller gets from it.

Key _key(String name) => Key('test.chip_$name');

/// The value without [name].
String _without(String names, String name) =>
    names.split(',').where((each) => each != name).join(',');

/// One chip per name in [names], each of which removes its name.
List<InUseChip<String>> _chips(String names) => [
  for (final name in names.split(','))
    if (name.isNotEmpty)
      (
        id: name,
        key: _key(name),
        label: name.toUpperCase(),
        semanticsLabel: 'the person $name',
        removeLabel: 'Remove $name',
        without: _without(names, name),
      ),
];

void main() {
  /// The chips for the names the page holds. A removal sets the value
  /// [answer] gives for the chip pressed: by default the one its removal
  /// leaves. A button above them stands for the caller's own control.
  /// Returns how often `onEmptied` was called, read through the getter.
  Future<int Function()> holdChips(
    WidgetTester tester,
    ValueNotifier<String> names, {
    String Function(InUseChip<String> chip)? answer,
  }) async {
    var emptied = 0;
    addTearDown(names.dispose);
    await tester.pumpWidget(
      gameFiltersApp(
        Scaffold(
          body: Column(
            children: [
              TextButton(onPressed: () {}, child: const Text('Elsewhere')),
              ValueListenableBuilder<String>(
                valueListenable: names,
                builder: (context, value, _) => InUseChips<String>(
                  value: value,
                  chips: _chips(value),
                  onRemove: (chip) =>
                      names.value = (answer ?? (chip) => chip.without)(chip),
                  onEmptied: () => emptied++,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return () => emptied;
  }

  /// The chip's own focus node.
  FocusNode chipFocus(WidgetTester tester, String name) =>
      tester.widget<InputChip>(find.byKey(_key(name))).focusNode!;

  Future<void> focusAndPress(WidgetTester tester, FocusNode node) async {
    node.requestFocus();
    await tester.pump();
    expect(node.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  testWidgets('draws a chip per entry, in order, named and spoken as given, '
      'and nothing with none', (tester) async {
    final handle = tester.ensureSemantics();
    final names = ValueNotifier('ada,bo');
    await holdChips(tester, names);

    expect(find.byType(InputChip), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.byKey(_key('ada'))).dx,
      lessThan(tester.getTopLeft(find.byKey(_key('bo'))).dx),
    );
    expect(
      find.descendant(of: find.byKey(_key('ada')), matching: find.text('ADA')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('the person ada'), findsOneWidget);
    expect(find.byTooltip('Remove bo'), findsOneWidget);

    names.value = '';
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsNothing);
    expect(find.byType(Wrap), findsNothing);
    handle.dispose();
  });

  testWidgets('a chip pressed is handed to onRemove, and its remove button '
      'hands it the same', (tester) async {
    final removed = <String>[];
    final names = ValueNotifier('ada,bo,cy');
    await holdChips(
      tester,
      names,
      answer: (chip) {
        removed.add(chip.id);
        return chip.without;
      },
    );

    await tester.tap(find.byKey(_key('bo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove cy'));
    await tester.pumpAndSettle();

    expect(removed, ['bo', 'cy']);
    expect(names.value, 'ada');
  });

  testWidgets('a focused chip removed hands focus to the chip in its place, '
      'the last in order to the one before it, and the only one to '
      'onEmptied', (tester) async {
    final names = ValueNotifier('ada,bo,cy');
    final emptied = await holdChips(tester, names);

    await focusAndPress(tester, chipFocus(tester, 'ada'));
    expect(chipFocus(tester, 'bo').hasPrimaryFocus, isTrue);

    await focusAndPress(tester, chipFocus(tester, 'cy'));
    expect(chipFocus(tester, 'bo').hasPrimaryFocus, isTrue);
    expect(emptied(), 0);

    await focusAndPress(tester, chipFocus(tester, 'bo'));
    expect(find.byType(InputChip), findsNothing);
    expect(emptied(), 1);
  });

  testWidgets('a chip removed by a pointer while another control holds '
      'focus moves no focus', (tester) async {
    final names = ValueNotifier('ada,bo');
    final emptied = await holdChips(tester, names);
    final elsewhere = Focus.of(tester.element(find.text('Elsewhere')))
      ..requestFocus();
    await tester.pump();

    await tester.tap(find.byKey(_key('ada')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_key('bo')));
    await tester.pumpAndSettle();

    expect(find.byType(InputChip), findsNothing);
    expect(elsewhere.hasPrimaryFocus, isTrue);
    expect(emptied(), 0);
  });

  testWidgets('a removal answered with another value hands nothing on, then '
      'or at a later change', (tester) async {
    final names = ValueNotifier('ada,bo,cy');
    // The caller answers a removal of Ada by letting Cy go.
    final emptied = await holdChips(
      tester,
      names,
      answer: (chip) => _without(names.value, 'cy'),
    );

    final ada = chipFocus(tester, 'ada');
    await focusAndPress(tester, ada);

    expect(find.byKey(_key('cy')), findsNothing);
    expect(ada.hasPrimaryFocus, isTrue);

    // The value that removal would have left, arriving later, settles
    // nothing: its hand-off was dropped.
    names.value = 'bo';
    await tester.pumpAndSettle();

    expect(find.byKey(_key('ada')), findsNothing);
    expect(chipFocus(tester, 'bo').hasPrimaryFocus, isFalse);
    expect(emptied(), 0);
  });
}
