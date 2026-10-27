import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

/// A list of tappable rows, one per name, keyed by the name.
///
/// Each row is a [ListTile] with an `onTap`, which is what makes it take
/// focus. The row carries no key of its own: the list keys it (#549).
Widget _list(List<String> names, {int semanticIndexOffset = 0}) => Scaffold(
  body: CustomScrollView(
    slivers: [
      BgeKeyedSliverList<String>(
        items: names,
        keyOf: ValueKey.new,
        semanticIndexOffset: semanticIndexOffset,
        itemBuilder: (context, name) =>
            ListTile(title: Text(name), onTap: () {}),
      ),
    ],
  ),
);

/// The title of the [ListTile] around whatever has primary focus.
String? _focusedRow() {
  final tile = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<ListTile>();
  return (tile?.title as Text?)?.data;
}

Future<void> _tabTo(
  WidgetTester tester,
  String name,
  List<String> names,
) async {
  for (var i = 0; i <= names.indexOf(name); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  }
  await tester.pump();
}

void main() {
  group('BgeKeyedSliverList', () {
    testWidgets('a row keeps its focus when a row above it leaves', (
      tester,
    ) async {
      const before = ['a', 'b', 'c', 'd'];
      await tester.pumpWidget(hostAtSize(tester, _list(before)));
      await _tabTo(tester, 'c', before);
      final node = FocusManager.instance.primaryFocus;
      expect(_focusedRow(), 'c');

      await tester.pumpWidget(hostAtSize(tester, _list(['b', 'c', 'd'])));
      await tester.pump();

      expect(_focusedRow(), 'c');
      expect(FocusManager.instance.primaryFocus, same(node));
    });

    testWidgets('a row keeps its focus when it moves down', (tester) async {
      const before = ['b', 'c', 'd'];
      await tester.pumpWidget(hostAtSize(tester, _list(before)));
      await _tabTo(tester, 'c', before);
      final node = FocusManager.instance.primaryFocus;
      expect(_focusedRow(), 'c');

      await tester.pumpWidget(hostAtSize(tester, _list(['a', 'b', 'c', 'd'])));
      await tester.pump();

      expect(_focusedRow(), 'c');
      expect(FocusManager.instance.primaryFocus, same(node));
    });

    testWidgets('finds each row by its key', (tester) async {
      await tester.pumpWidget(
        hostAtSize(tester, _list(const ['a', 'b', 'c', 'd'])),
      );

      final row = find.byKey(const ValueKey('c'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('c')),
        findsOneWidget,
      );
    });

    testWidgets('passes the semantic index offset through', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        hostAtSize(tester, _list(const ['a', 'b'], semanticIndexOffset: 5)),
      );

      expect(tester.getSemantics(find.text('a')).indexInParent, 5);
      expect(tester.getSemantics(find.text('b')).indexInParent, 6);

      handle.dispose();
    });
  });
}
