import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/l10n/game_catalog_localizations.dart';
import 'package:game_catalog/src/screens/search_range_field.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

// #50: a range field's accessible name carries its range, so a screen
// reader moving by form fields doesn't hear "From" three times. The name, the
// value and the error must be on the text field's own node, which is the one
// a screen reader lands on.

const _fromKey = Key('range_from');
const _toKey = Key('range_to');
const _tooLow = 'Must be at least 1';

Widget _app() => MaterialApp(
  theme: BgeTheme.light(),
  localizationsDelegates: GameCatalogLocalizations.localizationsDelegates,
  supportedLocales: GameCatalogLocalizations.supportedLocales,
  home: Scaffold(
    body: SearchRangeField(
      fromKey: _fromKey,
      toKey: _toKey,
      name: 'Players',
      value: const GameSearchRange(),
      lowest: 1,
      onCommit: (_) {},
    ),
  ),
);

/// The text field node named [name]. Found among the nodes flagged as text
/// fields, not with `tester.getSemantics`, which returns the nearest node at
/// or above a widget, and so could pass on a wrapper's node.
SemanticsData _field(String name) => find.semantics
    .byPredicate(
      (node) =>
          node.flagsCollection.isTextField &&
          node.getSemanticsData().label == name,
    )
    .evaluate()
    .single
    .getSemanticsData();

void main() {
  testWidgets('each field is named for its range and end', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app());

    expect(_field('Players, from').value, isEmpty);
    expect(_field('Players, to').value, isEmpty);
    handle.dispose();
  });

  testWidgets('a bound typed is the value of its field', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app());

    await tester.enterText(find.byKey(_fromKey), '2');
    await tester.pumpAndSettle();

    expect(_field('Players, from').value, '2');
    expect(_field('Players, to').value, isEmpty);
    handle.dispose();
  });

  testWidgets('a field in error carries its error, and the error is '
      'announced as it appears', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app());

    await tester.enterText(find.byKey(_fromKey), '0');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    final from = _field('Players, from');
    expect(from.value, '0');
    expect(from.hint, _tooLow);
    expect(_field('Players, to').hint, isEmpty);
    expect(
      find.semantics.byPredicate(
        (node) =>
            node.flagsCollection.isLiveRegion &&
            node.getSemanticsData().label == _tooLow,
      ),
      findsOne,
    );
    handle.dispose();
  });
}
