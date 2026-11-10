import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A tile that keeps a state of its own, and can take focus.
class _Tile extends StatefulWidget {
  const _Tile(this.name);

  final String name;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> {
  final focusNode = FocusNode();

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      InkWell(focusNode: focusNode, onTap: () {}, child: Text(widget.name));
}

const _stripKey = Key('strip');
const _stripHeight = 40.0;

/// Two columns: the window is narrower than [BgeTokens.breakpointMedium].
const _window = Size(400, 1200);

Widget _grid(
  List<String> names, {
  int? unfolded,
  int semanticIndexOffset = 0,
}) => Scaffold(
  body: CustomScrollView(
    slivers: [
      BgeUnfoldingCoverGrid<String>(
        items: names,
        keyOf: ValueKey.new,
        itemBuilder: (context, name) => _Tile(name),
        unfolded: unfolded,
        semanticIndexOffset: semanticIndexOffset,
        stripBuilder: (context, name) => SizedBox(
          key: _stripKey,
          height: _stripHeight,
          child: Text('strip of $name'),
        ),
      ),
    ],
  ),
);

Finder _tile(String name) => find.byKey(ValueKey(name));

/// The keyed grids the cover grid is drawn with.
final Finder _grids = find.byWidgetPredicate(
  (widget) => widget is BgeKeyedSliverGrid,
);

void main() {
  const six = ['a', 'b', 'c', 'd', 'e', 'f'];

  testWidgets('folded, it is one grid', (tester) async {
    await tester.pumpWidget(hostAtSize(tester, _grid(six), size: _window));

    expect(_grids, findsOneWidget);
    expect(find.byKey(_stripKey), findsNothing);
    for (final name in six) {
      expect(_tile(name), findsOneWidget);
    }
  });

  testWidgets("unfolded, the strip sits under the unfolded item's row", (
    tester,
  ) async {
    await tester.pumpWidget(
      hostAtSize(tester, _grid(six, unfolded: 2), size: _window),
    );
    final tokens = BgeTokens.of(tester.element(find.byKey(_stripKey)));

    expect(_grids, findsNWidgets(2));
    expect(find.text('strip of c'), findsOneWidget);
    final strip = tester.getRect(find.byKey(_stripKey));
    // Two columns: c is in the second row, with d.
    for (final name in ['a', 'b', 'c', 'd']) {
      expect(
        tester.getRect(_tile(name)).bottom,
        lessThanOrEqualTo(strip.top),
        reason: '$name is above the strip',
      );
    }
    for (final name in ['e', 'f']) {
      expect(
        tester.getRect(_tile(name)).top,
        greaterThanOrEqualTo(strip.bottom),
        reason: '$name is below the strip',
      );
    }
    // The strip is padded as the rows are spaced.
    expect(strip.top - tester.getRect(_tile('c')).bottom, tokens.spaceSm);
    expect(tester.getRect(_tile('e')).top - strip.bottom, tokens.spaceSm);
    // Full width: the strip is as wide as the two columns together.
    expect(strip.left, tester.getRect(_tile('c')).left);
    expect(strip.right, tester.getRect(_tile('d')).right);
  });

  testWidgets('the last row unfolded puts the strip at the end', (
    tester,
  ) async {
    const five = ['a', 'b', 'c', 'd', 'e'];
    await tester.pumpWidget(
      hostAtSize(tester, _grid(five, unfolded: 4), size: _window),
    );

    final strip = tester.getRect(find.byKey(_stripKey));
    for (final name in five) {
      expect(
        tester.getRect(_tile(name)).bottom,
        lessThanOrEqualTo(strip.top),
        reason: '$name is above the strip',
      );
    }
    expect(find.text('strip of e'), findsOneWidget);
  });

  testWidgets('a focused tile in the first row keeps its element as the '
      'strip opens and closes', (tester) async {
    await tester.pumpWidget(hostAtSize(tester, _grid(six), size: _window));
    final finder = find.descendant(
      of: _tile('b'),
      matching: find.byType(_Tile),
    );
    final state = tester.state<_TileState>(finder);
    state.focusNode.requestFocus();
    await tester.pump();
    expect(state.focusNode.hasPrimaryFocus, isTrue);

    for (final (step, unfolded) in [('opened', 1), ('closed', null)]) {
      await tester.pumpWidget(
        hostAtSize(tester, _grid(six, unfolded: unfolded), size: _window),
      );
      await tester.pump();

      expect(tester.state<_TileState>(finder), same(state), reason: step);
      expect(state.focusNode.hasPrimaryFocus, isTrue, reason: step);
    }
  });

  testWidgets('the covers after the strip count on from the ones before it', (
    tester,
  ) async {
    await tester.pumpWidget(
      hostAtSize(
        tester,
        _grid(six, unfolded: 0, semanticIndexOffset: 3),
        size: _window,
      ),
    );

    int indexOf(String name) => tester
        .widget<IndexedSemantics>(
          find.ancestor(
            of: _tile(name),
            matching: find.byType(IndexedSemantics),
          ),
        )
        .index;

    for (final (index, name) in six.indexed) {
      expect(indexOf(name), 3 + index, reason: name);
    }
    // The strip is not one of the covers.
    expect(
      find.ancestor(
        of: find.byKey(_stripKey),
        matching: find.byType(IndexedSemantics),
      ),
      findsNothing,
    );
  });

  testWidgets('another item unfolded opens a strip of its own', (tester) async {
    await tester.pumpWidget(
      hostAtSize(tester, _grid(six, unfolded: 0), size: _window),
    );
    final first = tester.element(find.byKey(_stripKey));

    await tester.pumpWidget(
      hostAtSize(tester, _grid(six, unfolded: 4), size: _window),
    );

    expect(find.text('strip of e'), findsOneWidget);
    expect(find.text('strip of a'), findsNothing);
    expect(
      tester.element(find.byKey(_stripKey)),
      isNot(same(first)),
      reason: "a new item's strip starts afresh, scrolled to its start",
    );
    final strip = tester.getRect(find.byKey(_stripKey));
    expect(tester.getRect(_tile('f')).bottom, lessThanOrEqualTo(strip.top));
  });

  group('BgeUnfoldingCovers', () {
    /// Items as (key, id, has a strip): the key can change while the id
    /// stays, as a game's tile does when it becomes a stack.
    Widget covers(List<(String, String, bool)> items) => Scaffold(
      body: CustomScrollView(
        slivers: [
          BgeUnfoldingCovers<(String, String, bool)>(
            items: items,
            keyOf: (item) => ValueKey(item.$1),
            idOf: (item) => item.$2,
            hasStrip: (item) => item.$3,
            itemBuilder: (context, item, unfolded, toggle) => TextButton(
              onPressed: toggle,
              child: Text('${item.$1}${unfolded ? ' open' : ''}'),
            ),
            stripBuilder: (context, item) => SizedBox(
              key: _stripKey,
              height: _stripHeight,
              child: Text('strip of ${item.$2}'),
            ),
          ),
        ],
      ),
    );

    final items = [
      for (final name in ['a', 'b', 'c', 'd']) (name, name, true),
    ];

    Future<void> toggle(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
    }

    testWidgets(
      'a toggle opens its strip and tells its tile; again closes it',
      (tester) async {
        await tester.pumpWidget(
          hostAtSize(tester, covers(items), size: _window),
        );

        await toggle(tester, 'c');
        expect(find.text('strip of c'), findsOneWidget);
        expect(find.text('c open'), findsOneWidget);

        await toggle(tester, 'c');
        expect(find.byKey(_stripKey), findsNothing);
        expect(find.text('c'), findsOneWidget);
      },
    );

    testWidgets('unfolding another folds the first', (tester) async {
      await tester.pumpWidget(hostAtSize(tester, covers(items), size: _window));

      await toggle(tester, 'a');
      await toggle(tester, 'd');

      expect(find.text('strip of d'), findsOneWidget);
      expect(find.text('strip of a'), findsNothing);
      expect(find.text('a'), findsOneWidget);
    });

    testWidgets("the unfold stays while the item's tile changes form", (
      tester,
    ) async {
      await tester.pumpWidget(hostAtSize(tester, covers(items), size: _window));
      await toggle(tester, 'b');
      final strip = tester.element(find.byKey(_stripKey));

      await tester.pumpWidget(
        hostAtSize(
          tester,
          covers([items[0], ('b-stack', 'b', true), ...items.skip(2)]),
          size: _window,
        ),
      );

      expect(find.text('strip of b'), findsOneWidget);
      expect(find.text('b-stack open'), findsOneWidget);
      expect(
        tester.element(find.byKey(_stripKey)),
        same(strip),
        reason: 'the same strip, so its shelf keeps its scroll and focus',
      );
    });

    for (final (why, gone) in [
      ('loses its strip', [items[0], ('b', 'b', false), ...items.skip(2)]),
      ('goes', [items[0], ...items.skip(2)]),
    ]) {
      testWidgets("the unfold goes when its item $why, and doesn't come back", (
        tester,
      ) async {
        await tester.pumpWidget(
          hostAtSize(tester, covers(items), size: _window),
        );
        await toggle(tester, 'b');

        await tester.pumpWidget(
          hostAtSize(tester, covers(gone), size: _window),
        );
        expect(find.byKey(_stripKey), findsNothing);

        await tester.pumpWidget(
          hostAtSize(tester, covers(items), size: _window),
        );
        expect(find.byKey(_stripKey), findsNothing);
        expect(find.text('b'), findsOneWidget);
      });
    }
  });
}
