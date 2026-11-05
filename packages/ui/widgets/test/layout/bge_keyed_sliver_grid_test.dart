import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _Counter extends StatefulWidget {
  const _Counter(this.name);

  final String name;

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => setState(() => taps++),
    child: Text('${widget.name}:$taps'),
  );
}

Widget _grid(List<String> names, {int semanticIndexOffset = 0}) => Scaffold(
  body: CustomScrollView(
    slivers: [
      BgeKeyedSliverGrid<String>(
        items: names,
        keyOf: ValueKey.new,
        semanticIndexOffset: semanticIndexOffset,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
        ),
        itemBuilder: (context, name) => _Counter(name),
      ),
    ],
  ),
);

void main() {
  group('BgeKeyedSliverGrid', () {
    testWidgets('grid: a tile keeps its state when the one before it leaves', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostAtSize(tester, _grid(const ['a', 'b', 'c', 'd'])),
      );
      await tester.tap(find.text('c:0'));
      await tester.pump();
      expect(find.text('c:1'), findsOneWidget);

      await tester.pumpWidget(hostAtSize(tester, _grid(const ['b', 'c', 'd'])));
      await tester.pump();

      expect(find.text('c:1'), findsOneWidget);
      expect(find.text('b:0'), findsOneWidget);
    });

    testWidgets('finds each tile by its key', (tester) async {
      await tester.pumpWidget(hostAtSize(tester, _grid(const ['a', 'b', 'c'])));

      final tile = find.byKey(const ValueKey('b'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.textContaining('b:')),
        findsOneWidget,
      );
    });
  });

  group('bgeGridColumns', () {
    const tokens = BgeTokens.standard;

    test('grid columns: 2 at 599, 3 at 600, 4 at 840', () {
      expect(bgeGridColumns(320, tokens), 2);
      expect(bgeGridColumns(599, tokens), 2);
      expect(bgeGridColumns(600, tokens), 3);
      expect(bgeGridColumns(839, tokens), 3);
      expect(bgeGridColumns(840, tokens), 4);
    });
  });

  group('bgeCoverGridDelegate', () {
    for (final (window, columns) in [(599.0, 2), (600.0, 3), (840.0, 4)]) {
      testWidgets('$columns columns on a ${window.toInt()}dp window, whatever '
          'the pane', (tester) async {
        late SliverGridDelegateWithFixedCrossAxisCount delegate;
        late BgeTokens tokens;
        await tester.pumpWidget(
          hostAtSize(
            tester,
            // A pane far narrower than the window: the columns follow the
            // window's size class, not the width the grid is given.
            Center(
              child: SizedBox(
                width: 200,
                child: Builder(
                  builder: (context) {
                    delegate = bgeCoverGridDelegate(context);
                    tokens = BgeTokens.of(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
            size: Size(window, 800),
          ),
        );

        expect(delegate.crossAxisCount, columns);
        expect(delegate.mainAxisSpacing, tokens.spaceSm);
        expect(delegate.crossAxisSpacing, tokens.spaceSm);
      });
    }
  });
}
