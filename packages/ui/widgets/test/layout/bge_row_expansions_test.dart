import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A game in these tests: its id and its title.
typedef _Game = ({String id, String title});

_Game _game(String id) => (id: id, title: 'Game $id');

/// [count] expansions of the base game [parent].
List<_Game> _expansionsOf(String parent, int count) => [
  for (var i = 0; i < count; i++) (id: '$parent.$i', title: 'Expansion $i'),
];

/// What a row's control says and does in these tests (#1048).
BgeCoverExpansions _expansions({
  String title = 'Wingspan',
  int count = 2,
  bool expanded = false,
  VoidCallback? onToggle,
}) => BgeCoverExpansions(
  count: count,
  expanded: expanded,
  onToggle: onToggle ?? () {},
  label: '$title expansions, $count',
  showLabel: 'Show expansions',
  hideLabel: 'Hide expansions',
);

/// A row as the list screens build one (#647, #758): outlined, merged into
/// one node, ringed and tappable, indented under its base game when
/// [nested]. With [expansions] the tile offers the custom action, and the
/// control sits beside it, at the row's end, outside the tile's node and
/// after its focus ([BgeExpansionsRow]).
Widget _row(
  String title, {
  Key? key,
  BgeCoverExpansions? expansions,
  VoidCallback? onOpen,
  bool nested = false,
  bool inert = false,
}) => Padding(
  key: key,
  padding: EdgeInsetsDirectional.only(
    start: nested ? BgeTokens.spaceLgValue : 0,
  ),
  child: BgeOutlinedRow(
    child: BgeExpansionsRow(
      expansions: expansions,
      builder: (context, focusNode) => BgeRowFocusRing(
        focusNode: focusNode,
        builder: (_, row) => ListTile(
          focusNode: row.focusNode,
          onFocusChange: row.onFocusChange,
          focusColor: row.focusColor,
          onTap: row.onTap(inert ? null : onOpen ?? () {}),
          title: Text(title),
          subtitle: const Text('2 to 4 players'),
        ),
      ),
    ),
  ),
);

/// The groups a [_FoldingList] lays out, which a test changes as a page or
/// a sync would.
ValueNotifier<List<(_Game, List<_Game>)>> _groups(
  List<(_Game, List<_Game>)> groups,
) {
  final notifier = ValueNotifier(groups);
  addTearDown(notifier.dispose);
  return notifier;
}

Widget _app(Widget home, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? BgeTheme.light(), home: home);

/// A list page of [groups], folded and unfolded through [BgeOpenRows] and
/// [foldNested], with each row in its game's [BgeFocusHandoff], as the
/// screens lay theirs out (#1048).
class _FoldingList extends StatefulWidget {
  const _FoldingList({
    required this.groups,
    this.onOpen,
    this.inert = false,
  });

  final ValueListenable<List<(_Game, List<_Game>)>> groups;
  final void Function(_Game game)? onOpen;

  /// Whether the rows open nothing, and so take no focus: only the controls
  /// are stops.
  final bool inert;

  @override
  State<_FoldingList> createState() => _FoldingListState();
}

class _FoldingListState extends State<_FoldingList> {
  final BgeOpenRows open = BgeOpenRows();

  @override
  void initState() {
    super.initState();
    open.addListener(_changed);
    widget.groups.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.groups.removeListener(_changed);
    open
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  Widget _nested(_Game parent, _Game game) => BgeFocusHandoff(
    key: ValueKey('nested.${game.id}'),
    identity: game.id,
    place: parent.id,
    child: _row(
      game.title,
      nested: true,
      inert: widget.inert,
      onOpen: () => widget.onOpen?.call(game),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final groups = widget.groups.value;
    open.retain([
      for (final (top, nested) in groups)
        if (nested.isNotEmpty) top.id,
    ]);
    final rows = foldNested<_Game>(
      groups: groups,
      open: open.open,
      idOf: (game) => game.id,
    );
    return BgePage.slivers(
      title: const Text('Games'),
      width: BgePageWidth.pane,
      slivers: [
        BgeFocusHandoffScope(
          child: SliverList.list(
            children: [
              for (final row in rows)
                switch (row) {
                  BgeTopRow(:final item, :final nested, open: final on) =>
                    BgeFocusHandoff(
                      key: ValueKey('top.${item.id}'),
                      identity: item.id,
                      folded: {
                        if (!on)
                          for (final game in nested) game.id,
                      },
                      foldedPlace: item.id,
                      foldedControl: BgeRowExpansionsControl.foldedControl,
                      child: _row(
                        item.title,
                        inert: widget.inert,
                        onOpen: () => widget.onOpen?.call(item),
                        expansions: nested.isEmpty
                            ? null
                            : _expansions(
                                title: item.title,
                                count: nested.length,
                                expanded: on,
                                onToggle: () => open.toggle(item.id),
                              ),
                      ),
                    ),
                  BgeNestedRow(:final parent, :final item) => _nested(
                    parent,
                    item,
                  ),
                  BgeNestedBox(:final parent, :final items) => BgeNestedRowsBox(
                    key: ValueKey('box.${parent.id}'),
                    semanticLabel: '${parent.title} expansions',
                    rows: [for (final game in items) _nested(parent, game)],
                  ),
                },
            ],
          ),
        ),
      ],
    );
  }
}

Finder _controlOf(String title) => find.descendant(
  of: find.ancestor(
    of: find.text(title),
    matching: find.byType(BgeOutlinedRow),
  ),
  matching: find.byType(BgeRowExpansionsControl),
);

/// The control's own node: the ink inside it walks up to it.
SemanticsNode _controlNode(WidgetTester tester, Finder control) =>
    tester.getSemantics(
      find.descendant(of: control, matching: find.byType(InkWell)),
    );

/// The row's merged node, which its title walks up to.
SemanticsNode _rowNode(WidgetTester tester, String title) =>
    tester.getSemantics(find.text(title));

/// Performs the custom action called [label] on [node].
void _performCustomAction(SemanticsNode node, String label) =>
    node.owner!.performAction(
      node.id,
      SemanticsAction.customAction,
      CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label)),
    );

/// Whether the primary focus is inside [control].
bool _focusIsIn(WidgetTester tester, Finder control) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return tester.widget(control) ==
      focused.findAncestorWidgetOfExactType<BgeRowExpansionsControl>();
}

/// The focus node of the control at the end of the row titled [title].
FocusNode _controlFocus(WidgetTester tester, String title) => Focus.of(
  tester.element(
    find.descendant(of: _controlOf(title), matching: find.byType(Icon)),
  ),
);

/// The focus node of the row titled [title].
FocusNode _rowFocus(WidgetTester tester, String title) => Focus.of(
  tester.element(
    find
        .descendant(
          of: find.ancestor(
            of: find.text(title),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(Text),
        )
        .first,
  ),
);

void main() {
  group('foldNested', () {
    final groups = [
      ('a', ['a1', 'a2']),
      ('b', <String>[]),
      ('c', ['c1', 'c2', 'c3', 'c4']),
      ('d', ['d1', 'd2', 'd3', 'd4', 'd5']),
    ];
    List<BgeFoldedRow<String>> fold(Set<Object> open) =>
        foldNested(groups: groups, open: open, idOf: (id) => id);

    test('folded by default', () {
      expect(fold(const {}), const [
        BgeTopRow('a', nested: ['a1', 'a2']),
        BgeTopRow('b'),
        BgeTopRow('c', nested: ['c1', 'c2', 'c3', 'c4']),
        BgeTopRow('d', nested: ['d1', 'd2', 'd3', 'd4', 'd5']),
      ]);
    });

    test('4 nested open inline', () {
      expect(BgeNestedRowsBox.inlineLimit, 4);
      expect(fold({'c'}), const [
        BgeTopRow('a', nested: ['a1', 'a2']),
        BgeTopRow('b'),
        BgeTopRow('c', nested: ['c1', 'c2', 'c3', 'c4'], open: true),
        BgeNestedRow('c', 'c1'),
        BgeNestedRow('c', 'c2'),
        BgeNestedRow('c', 'c3'),
        BgeNestedRow('c', 'c4'),
        BgeTopRow('d', nested: ['d1', 'd2', 'd3', 'd4', 'd5']),
      ]);
    });

    test('5 nested open as one box', () {
      expect(fold({'d'}), const [
        BgeTopRow('a', nested: ['a1', 'a2']),
        BgeTopRow('b'),
        BgeTopRow('c', nested: ['c1', 'c2', 'c3', 'c4']),
        BgeTopRow('d', nested: ['d1', 'd2', 'd3', 'd4', 'd5'], open: true),
        BgeNestedBox('d', ['d1', 'd2', 'd3', 'd4', 'd5']),
      ]);
    });

    test('several open at once', () {
      expect(fold({'a', 'd'}), const [
        BgeTopRow('a', nested: ['a1', 'a2'], open: true),
        BgeNestedRow('a', 'a1'),
        BgeNestedRow('a', 'a2'),
        BgeTopRow('b'),
        BgeTopRow('c', nested: ['c1', 'c2', 'c3', 'c4']),
        BgeTopRow('d', nested: ['d1', 'd2', 'd3', 'd4', 'd5'], open: true),
        BgeNestedBox('d', ['d1', 'd2', 'd3', 'd4', 'd5']),
      ]);
    });

    test('an open game with nothing nested is a top row alone, not open', () {
      expect(fold({'b'}), const [
        BgeTopRow('a', nested: ['a1', 'a2']),
        BgeTopRow('b'),
        BgeTopRow('c', nested: ['c1', 'c2', 'c3', 'c4']),
        BgeTopRow('d', nested: ['d1', 'd2', 'd3', 'd4', 'd5']),
      ]);
    });

    test('the rows are equal by value, and tell their kinds apart', () {
      expect(const BgeTopRow('a', nested: ['b', 'c']).nestedCount, 2);
      expect(const BgeTopRow('a').nestedCount, 0);
      expect(
        const BgeTopRow('a', nested: ['b']),
        isNot(const BgeTopRow('a', nested: ['c'])),
      );
      expect(
        const BgeTopRow('a', nested: ['b']).hashCode,
        BgeTopRow('a', nested: List.of(['b'])).hashCode,
      );
      expect(const BgeTopRow('a'), isNot(const BgeTopRow('a', open: true)));
      expect(const BgeNestedRow('a', 'b'), isNot(const BgeNestedRow('b', 'a')));
      expect(
        const BgeNestedBox('a', ['b']).hashCode,
        const BgeNestedBox('a', ['b']).hashCode,
      );
      expect(
        const BgeNestedBox('a', ['b']),
        isNot(const BgeNestedRow('a', 'b')),
      );
    });
  });

  group('BgeOpenRows', () {
    test('keeps an id across a rebuild with new pages and drops it when its '
        'game goes', () {
      final open = BgeOpenRows();
      addTearDown(open.dispose);
      var notified = 0;
      open.addListener(() => notified++);

      expect(open.isOpen('a'), isFalse, reason: 'folded by default');
      open.toggle('a');
      expect(open.isOpen('a'), isTrue);
      expect(notified, 1);

      // A new page brings more games: the open one stays open.
      open
        ..retain(['a', 'b'])
        ..retain(['a', 'b', 'c', 'd']);
      expect(open.isOpen('a'), isTrue);
      expect(open.open, {'a'});
      expect(
        foldNested(
          groups: [
            ('a', ['a1']),
            ('c', ['c1']),
          ],
          open: open.open,
          idOf: (id) => id,
        ),
        const [
          BgeTopRow('a', nested: ['a1'], open: true),
          BgeNestedRow('a', 'a1'),
          BgeTopRow('c', nested: ['c1']),
        ],
      );

      // Its game goes: the id goes with it, and the game comes back folded.
      open.retain(['b', 'c']);
      expect(open.isOpen('a'), isFalse);
      open.retain(['a', 'b', 'c']);
      expect(open.isOpen('a'), isFalse);

      // retain tells no one, so a build can call it.
      expect(notified, 1);

      open
        ..toggle('b')
        ..toggle('c')
        ..toggle('b');
      expect(open.open, {'c'});
      expect(notified, 4);

      // A live view, which can't be changed through it.
      final view = open.open;
      open.toggle('e');
      expect(view, {'c', 'e'});
      expect(() => view.add('f'), throwsUnsupportedError);
    });
  });

  group('BgeFoldedRow.items', () {
    test('the games an entry draws rows for', () {
      expect(const BgeTopRow('a', nested: ['b']).items, ['a']);
      expect(const BgeNestedRow('a', 'b').items, ['b']);
      expect(const BgeNestedBox('a', ['b', 'c']).items, ['b', 'c']);
    });
  });

  group('BgeOpenRows.foldAll', () {
    test('folds every game, and tells no one, so a build can call it', () {
      final open = BgeOpenRows();
      addTearDown(open.dispose);
      var notified = 0;
      open
        ..toggle('a')
        ..toggle('b')
        ..addListener(() => notified++)
        ..foldAll();
      expect(open.open, isEmpty);
      expect(open.isOpen('a'), isFalse);
      expect(notified, 0);
    });
  });

  group('BgeFoldedHandoffs', () {
    final box = BgeFoldedHandoffs.boxIdentity('d');
    const nested = ['d1', 'd2', 'd3', 'd4', 'd5'];
    const child = SizedBox();
    BgeFoldedHandoffs<String> handoffs({bool boxIsStop = false}) =>
        BgeFoldedHandoffs(idOf: (id) => id, boxIsStop: boxIsStop);

    test('a top row names its game, and while folded its nested games, in '
        'its own place, behind its control', () {
      final folded = handoffs().topRow(
        const BgeTopRow('d', nested: nested),
        child: child,
      );
      expect(folded.identity, 'd');
      expect(folded.place, isNull);
      expect(folded.folded, nested.toSet());
      expect(folded.foldedPlace, 'd');
      expect(folded.foldedControl, BgeRowExpansionsControl.foldedControl);
      expect(folded.child, same(child));

      final open = handoffs().topRow(
        const BgeTopRow('d', nested: nested, open: true),
        child: child,
      );
      expect(open.folded, isEmpty);
      expect(open.foldedPlace, 'd');
    });

    test('a box that is a stop of its own folds behind the control too, '
        'wherever it is not shown', () {
      final stop = handoffs(boxIsStop: true);
      expect(
        stop.topRow(const BgeTopRow('d', nested: nested), child: child).folded,
        {...nested, box},
      );
      expect(
        stop
            .topRow(
              const BgeTopRow('d', nested: nested, open: true),
              child: child,
            )
            .folded,
        isEmpty,
        reason: 'open with more than inlineLimit: the box is shown',
      );
      expect(
        stop
            .topRow(
              const BgeTopRow('c', nested: ['c1', 'c2'], open: true),
              child: child,
            )
            .folded,
        {BgeFoldedHandoffs.boxIdentity('c')},
        reason: 'open with no more than inlineLimit: no box is built',
      );
    });

    test('a box that is a stop is an item of its own under its base game, '
        "and one that isn't is no item: its rows' own hand theirs on", () {
      final item = handoffs(boxIsStop: true).box(
        const BgeNestedBox('d', nested),
        child: child,
      ) as BgeFocusHandoff;
      expect(item.identity, box);
      expect(item.place, 'd');
      expect(item.child, same(child));

      expect(
        handoffs().box(const BgeNestedBox('d', nested), child: child),
        same(child),
      );
    });

    test('isShownIn: each game in its place, and a box that is a stop', () {
      final rows = foldNested(
        groups: [
          ('a', ['a1']),
          ('c', ['c1', 'c2']),
          ('d', nested),
        ],
        open: {'a', 'd'},
        idOf: (id) => id,
      );
      for (final boxIsStop in [false, true]) {
        final isShown = handoffs(boxIsStop: boxIsStop).isShownIn(rows);
        expect(isShown('a', null), isTrue);
        expect(isShown('a1', 'a'), isTrue);
        expect(isShown('a1', null), isFalse);
        expect(isShown('c', null), isTrue);
        expect(isShown('c1', 'c'), isFalse, reason: 'folded away');
        expect(isShown('d5', 'd'), isTrue, reason: 'in the box');
        expect(isShown(box, 'd'), boxIsStop);
      }
    });
  });

  group('BgeRowExpansionsControl', () {
    testWidgets('named "<title> expansions, 2, collapsed", expanded state, '
        'toggles', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        var toggles = 0;
        for (final expanded in [false, true]) {
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: _row(
                  'Wingspan',
                  expansions: _expansions(
                    expanded: expanded,
                    onToggle: () => toggles++,
                  ),
                ),
              ),
            ),
          );

          final control = find.byType(BgeRowExpansionsControl);
          final node = _controlNode(tester, control);
          expect(
            node,
            isSemantics(
              label: 'Wingspan expansions, 2',
              isButton: true,
              hasExpandedState: true,
              isExpanded: expanded,
              hasTapAction: true,
              isFocusable: true,
            ),
            reason: 'expanded: $expanded',
          );
          expect(node.childrenCount, 0);
          // The control is a node of its own, not merged into the row's.
          final row = _rowNode(tester, 'Wingspan');
          expect(row.id, isNot(node.id));
          expect(row.getSemanticsData().label, isNot(contains('expansions')));
          // The drawn count isn't read a second time.
          expect(find.bySemanticsLabel('2'), findsNothing);

          final before = toggles;
          await tester.tap(control);
          await tester.pump();
          expect(toggles, before + 1, reason: 'a tap toggles');
          expect(_focusIsIn(tester, control), isTrue, reason: 'a tap focuses');
        }
      } finally {
        handle.dispose();
      }
    });

    testWidgets('it is the cover badge: one look', (tester) async {
      await tester.pumpWidget(
        _app(Scaffold(body: _row('Wingspan', expansions: _expansions()))),
      );
      final control = find.byType(BgeRowExpansionsControl);
      expect(
        find.descendant(of: control, matching: find.byIcon(Icons.extension)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: control, matching: find.text('2')),
        findsOneWidget,
      );
      final fill =
          tester
                  .widget<Ink>(
                    find.descendant(of: control, matching: find.byType(Ink)),
                  )
                  .decoration!
              as BoxDecoration;
      expect(
        fill.color,
        BgeTheme.light().colorScheme.surfaceContainerHighest,
      );
      expect(find.byKey(BgeStackMarker.badgeKey), findsNothing);
    });

    testWidgets('the row offers Show expansions, and Hide expansions when '
        'open', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        var toggles = 0;
        for (final (expanded, action) in [
          (false, 'Show expansions'),
          (true, 'Hide expansions'),
        ]) {
          await tester.pumpWidget(
            _app(
              Scaffold(
                body: _row(
                  'Wingspan',
                  expansions: _expansions(
                    expanded: expanded,
                    onToggle: () => toggles++,
                  ),
                ),
              ),
            ),
          );

          final row = _rowNode(tester, 'Wingspan');
          expect(
            row,
            isSemantics(
              hasTapAction: true,
              customActions: [CustomSemanticsAction(label: action)],
            ),
            reason: action,
          );
          final before = toggles;
          _performCustomAction(row, action);
          expect(toggles, before + 1, reason: action);
        }
      } finally {
        handle.dispose();
      }
    });

    testWidgets('Tab reaches the control after the row, and Enter on the row '
        'opens the game', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        _app(
          _FoldingList(
            groups: _groups([
              (_game('a'), _expansionsOf('a', 2)),
              (_game('b'), []),
            ]),
            onOpen: (game) => opened.add(game.id),
          ),
        ),
      );

      _rowFocus(tester, 'Game a').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened, ['a'], reason: 'Enter on the row opens the game');
      expect(find.text('Expansion 0'), findsNothing, reason: 'still folded');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusIsIn(tester, _controlOf('Game a')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Expansion 0'), findsOneWidget, reason: 'unfolded');
      expect(_focusIsIn(tester, _controlOf('Game a')), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        _rowFocus(tester, 'Expansion 0'),
        reason: 'the nested rows follow the control',
      );
    });

    for (final count in [2, 6]) {
      testWidgets('folding with focus on a nested row hands it to the base '
          "game's control — $count nested", (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            _app(
              _FoldingList(
                groups: _groups([
                  (_game('a'), _expansionsOf('a', count)),
                  (_game('b'), _expansionsOf('b', 1)),
                ]),
              ),
            ),
          );
          await tester.tap(_controlOf('Game a'));
          await tester.pumpAndSettle();
          expect(
            find.byType(BgeNestedRowsBox),
            count > BgeNestedRowsBox.inlineLimit
                ? findsOneWidget
                : findsNothing,
          );

          _rowFocus(tester, 'Expansion 1').requestFocus();
          await tester.pump();

          // A screen reader on the base row folds it, as its custom action.
          _performCustomAction(_rowNode(tester, 'Game a'), 'Hide expansions');
          await tester.pumpAndSettle();

          expect(find.text('Expansion 1'), findsNothing, reason: 'folded');
          expect(_focusIsIn(tester, _controlOf('Game a')), isTrue);
          expect(
            _controlNode(tester, _controlOf('Game a')),
            isSemantics(
              label: 'Game a expansions, $count',
              hasExpandedState: true,
              isExpanded: false,
              isButton: true,
              hasTapAction: true,
              isFocusable: true,
              isFocused: true,
            ),
          );
        } finally {
          handle.dispose();
        }
      });
    }

    testWidgets('takes the focus node it is given', (tester) async {
      final node = FocusNode(debugLabel: 'control');
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: BgeRowExpansionsControl(
              expansions: _expansions(),
              focusNode: node,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(BgeRowExpansionsControl));
      await tester.pump();
      expect(node.hasPrimaryFocus, isTrue);
    });

    testWidgets('the last expansion going while the control has focus gives '
        "it to the row's tile, not the control focused before", (tester) async {
      final groups = _groups([
        (_game('a'), _expansionsOf('a', 2)),
        (_game('b'), []),
      ]);
      await tester.pumpWidget(_app(_FoldingList(groups: groups)));
      final tile = _rowFocus(tester, 'Game a');
      // From the next game's row, so the control the page focused before
      // this one is that row, not this one's tile, where the framework would
      // put focus anyway.
      _rowFocus(tester, 'Game b').requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(_focusIsIn(tester, _controlOf('Game a')), isTrue);

      // A sync takes the game's expansions.
      groups.value = [(_game('a'), []), (_game('b'), [])];
      await tester.pump();

      expect(_controlOf('Game a'), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(tile));
      expect(_rowFocus(tester, 'Game a'), same(tile), reason: 'the same tile');
    });

    testWidgets('the last expansion going under a covering route: the pop '
        "gives focus to the row's tile", (tester) async {
      final groups = _groups([
        (_game('a'), _expansionsOf('a', 2)),
        (_game('b'), []),
      ]);
      await tester.pumpWidget(_app(_FoldingList(groups: groups)));
      final tile = _rowFocus(tester, 'Game a');
      // From the next game's row, so the control the page focused before
      // this one is that row, not this one's tile, where the framework would
      // put focus anyway.
      _rowFocus(tester, 'Game b').requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(_focusIsIn(tester, _controlOf('Game a')), isTrue);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator))
        ..push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Details')),
          ),
        );
      await tester.pumpAndSettle();

      groups.value = [(_game('a'), []), (_game('b'), [])];
      await tester.pump();

      navigator.pop();
      await tester.pumpAndSettle();

      expect(_controlOf('Game a'), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(tile));
    });

    group('the last expansion going while the control of a row that takes '
        'no focus has it', () {
      // The rows open nothing, so the controls are the only stops: the tile
      // can't take the focus, and it must not fall to the page.
      testWidgets('hands it to the next stop after the row', (tester) async {
        final groups = _groups([
          (_game('x'), _expansionsOf('x', 1)),
          (_game('a'), _expansionsOf('a', 2)),
          (_game('b'), []),
          (_game('c'), _expansionsOf('c', 1)),
        ]);
        await tester.pumpWidget(
          _app(_FoldingList(groups: groups, inert: true)),
        );
        // From the control before, so the framework's history would give
        // the focus back to it: the stop before, not the one after.
        _controlFocus(tester, 'Game x').requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(_focusIsIn(tester, _controlOf('Game a')), isTrue);

        // A sync takes the game's expansions.
        groups.value = [
          (_game('x'), _expansionsOf('x', 1)),
          (_game('a'), []),
          (_game('b'), []),
          (_game('c'), _expansionsOf('c', 1)),
        ];
        await tester.pump();

        expect(
          FocusManager.instance.primaryFocus,
          same(_controlFocus(tester, 'Game c')),
          reason: 'past the row after it, which takes no focus either',
        );
        // The control stays until the focus has moved on, then goes.
        await tester.pump();
        expect(_controlOf('Game a'), findsNothing);
        expect(
          FocusManager.instance.primaryFocus,
          same(_controlFocus(tester, 'Game c')),
        );
      });

      testWidgets('hands it on when the same frame builds a new stop above '
          'the row', (tester) async {
        final groups = _groups([
          (_game('x'), _expansionsOf('x', 1)),
          (_game('a'), _expansionsOf('a', 2)),
          (_game('c'), _expansionsOf('c', 1)),
        ]);
        await tester.pumpWidget(
          _app(_FoldingList(groups: groups, inert: true)),
        );
        _controlFocus(tester, 'Game a').requestFocus();
        await tester.pump();

        // One sync takes the game's expansions and adds a game above it,
        // whose control is built in that frame, before the row is updated:
        // a stop with no size yet, which Tab's order can't be read with
        // until the page is laid out.
        groups.value = [
          (_game('x'), _expansionsOf('x', 1)),
          (_game('n'), _expansionsOf('n', 1)),
          (_game('a'), []),
          (_game('c'), _expansionsOf('c', 1)),
        ];
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(_controlOf('Game a'), findsNothing);
        expect(
          FocusManager.instance.primaryFocus,
          same(_controlFocus(tester, 'Game c')),
        );
      });

      testWidgets('hands it to the stop before the row when the one after '
          'goes in the same frame', (tester) async {
        final groups = _groups([
          (_game('x'), _expansionsOf('x', 1)),
          (_game('a'), _expansionsOf('a', 2)),
          (_game('c'), _expansionsOf('c', 1)),
        ]);
        await tester.pumpWidget(
          _app(_FoldingList(groups: groups, inert: true)),
        );
        // Straight to the control, so the page's focus history holds nothing
        // before it, and the framework would leave the focus on the page.
        _controlFocus(tester, 'Game a').requestFocus();
        await tester.pump();

        // One sync takes the game's expansions and the next game with them.
        groups.value = [
          (_game('x'), _expansionsOf('x', 1)),
          (_game('a'), []),
        ];
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('Game c'), findsNothing);
        expect(
          FocusManager.instance.primaryFocus,
          same(_controlFocus(tester, 'Game x')),
        );
      });

      testWidgets('hands it to the stop before the row when none comes after', (
        tester,
      ) async {
        final groups = _groups([
          (_game('x'), _expansionsOf('x', 1)),
          (_game('b'), []),
          (_game('a'), _expansionsOf('a', 2)),
        ]);
        await tester.pumpWidget(
          _app(_FoldingList(groups: groups, inert: true)),
        );
        // Straight to the control, so the page's focus history holds nothing
        // before it, and the framework would leave the focus on the page.
        _controlFocus(tester, 'Game a').requestFocus();
        await tester.pump();

        groups.value = [
          (_game('x'), _expansionsOf('x', 1)),
          (_game('b'), []),
          (_game('a'), []),
        ];
        await tester.pump();

        expect(
          FocusManager.instance.primaryFocus,
          same(_controlFocus(tester, 'Game x')),
        );
      });
    });

    testWidgets('several base games stay open at once, and new pages keep '
        'them open', (tester) async {
      final first = [
        (_game('a'), _expansionsOf('a', 1)),
        (_game('b'), _expansionsOf('b', 1)),
      ];
      final groups = _groups(first);
      await tester.pumpWidget(_app(_FoldingList(groups: groups)));
      await tester.tap(_controlOf('Game a'));
      await tester.pumpAndSettle();
      await tester.tap(_controlOf('Game b'));
      await tester.pumpAndSettle();
      expect(find.text('Expansion 0'), findsNWidgets(2));

      groups.value = [...first, (_game('c'), _expansionsOf('c', 1))];
      await tester.pumpAndSettle();
      expect(find.text('Game c'), findsOneWidget);
      expect(find.text('Expansion 0'), findsNWidgets(2), reason: 'c folded');
    });

    testWidgets('the badge holds contrast on an outlined row in all four '
        'themes', (tester) async {
      // Its name is not its drawn text, so the contrast guideline doesn't
      // measure it: the colours are checked here.
      final themes = {
        'light': BgeTheme.light(),
        'dark': BgeTheme.dark(),
        'high-contrast light': BgeTheme.highContrastLight(),
        'high-contrast dark': BgeTheme.highContrastDark(),
      };
      for (final MapEntry(key: name, value: theme) in themes.entries) {
        // A fresh app, so the theme doesn't animate from the last one.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _app(
            Scaffold(body: _row('Wingspan', expansions: _expansions())),
            theme: theme,
          ),
        );
        final control = find.byType(BgeRowExpansionsControl);
        final fill =
            (tester
                        .widget<Ink>(
                          find.descendant(
                            of: control,
                            matching: find.byType(Ink),
                          ),
                        )
                        .decoration!
                    as BoxDecoration)
                .color!;
        final border = tester
            .widgetList<DecoratedBox>(
              find.descendant(of: control, matching: find.byType(DecoratedBox)),
            )
            .map((box) => box.decoration)
            .whereType<BoxDecoration>()
            .map((decoration) => decoration.border)
            .whereType<Border>()
            .single
            .top
            .color;
        final icon = tester
            .widget<Icon>(
              find.descendant(of: control, matching: find.byType(Icon)),
            )
            .color!;
        final count = tester
            .widget<Text>(
              find.descendant(of: control, matching: find.text('2')),
            )
            .style!
            .color!;
        final page = theme.scaffoldBackgroundColor;

        expect(
          Wcag.contrastRatio(count, fill),
          greaterThanOrEqualTo(Wcag.aaNormalText),
          reason: '$name count',
        );
        expect(
          Wcag.contrastRatio(icon, fill),
          greaterThanOrEqualTo(3),
          reason: '$name icon',
        );
        expect(
          Wcag.contrastRatio(border, fill),
          greaterThanOrEqualTo(3),
          reason: '$name border on the fill',
        );
        expect(
          Wcag.contrastRatio(border, page),
          greaterThanOrEqualTo(3),
          reason: '$name border on the row',
        );
      }
    });

    testWidgets('a keyboard focus ring on the row control is the single '
        'primary tone, not the over-a-picture pair', (tester) async {
      await tester.pumpWidget(
        _app(Scaffold(body: _row('Wingspan', expansions: _expansions()))),
      );
      final ring = tester.widget<BgeFocusRing>(
        find.descendant(
          of: find.byType(BgeRowExpansionsControl),
          matching: find.byType(BgeFocusRing),
        ),
      );
      expect(ring.overPicture, isFalse);
    });

    testWidgets('at 320 dp × 2.0 the control is a whole target inside its '
        'outlined row, and the title keeps room', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          hostAtSize(
            tester,
            BgePage.slivers(
              title: const Text('Games'),
              width: BgePageWidth.pane,
              slivers: [
                SliverList.list(
                  children: [
                    _row(
                      'Wingspan: European Expansion',
                      expansions: _expansions(count: 12),
                    ),
                  ],
                ),
              ],
            ),
            size: const Size(320, 640),
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));

        const tokens = BgeTokens.standard;
        final control = find.byType(BgeRowExpansionsControl);
        final target = tester.getRect(
          find.descendant(of: control, matching: find.byType(InkWell)),
        );
        final outline = tester.getRect(
          find
              .descendant(
                of: find.byType(BgeOutlinedRow),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(target.width, greaterThanOrEqualTo(tokens.minTapTarget));
        expect(target.height, greaterThanOrEqualTo(tokens.minTapTarget));
        expect(outline.intersect(target), target, reason: 'inside the row');
        expect(
          tester.getRect(find.text('Wingspan: European Expansion')).width,
          greaterThan(outline.width / 3),
          reason: 'the title keeps most of the row',
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('on a tall row at 320 dp × 2.0 the control lines up with the '
        "title's first line, as a row's thumbnail does, not the row's middle", (
      tester,
    ) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          BgePage.slivers(
            title: const Text('Games'),
            width: BgePageWidth.pane,
            slivers: [
              SliverList.list(
                children: [
                  _row(
                    'Wingspan: European Expansion',
                    expansions: _expansions(count: 12),
                  ),
                ],
              ),
            ],
          ),
          size: const Size(320, 640),
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      final row = tester.getRect(find.byType(BgeExpansionsRow));
      final badge = tester.getRect(
        find.descendant(
          of: find.byType(BgeRowExpansionsControl),
          matching: find.byType(InkWell),
        ),
      );
      expect(
        row.height,
        greaterThan(2 * badge.height),
        reason: 'a row tall enough to tell the top from the middle',
      );
      // Where a list row's thumbnail goes at this size: 16dp down.
      expect(badge.top - row.top, closeTo(BgeTokens.standard.spaceMd, 0.01));
    });

    testWidgets('at the default text size the control stays in the middle '
        'of its row', (tester) async {
      await tester.pumpWidget(
        _app(Scaffold(body: _row('Wingspan', expansions: _expansions()))),
      );
      final row = tester.getRect(find.byType(BgeExpansionsRow));
      final control = tester.getRect(find.byType(BgeRowExpansionsControl));
      expect(control.center.dy, closeTo(row.center.dy, 0.01));
    });
  });

  group('accessibility audit', () {
    for (final open in [false, true]) {
      auditScreen(
        'an outlined row with its control, ${open ? 'open' : 'folded'}',
        build: (theme) => MaterialApp(
          theme: theme,
          home: BgePage.slivers(
            title: const Text('Games'),
            width: BgePageWidth.pane,
            slivers: [
              SliverList.list(
                children: [
                  _row(
                    'Wingspan: European Expansion',
                    expansions: _expansions(count: 12, expanded: open),
                  ),
                  if (open)
                    for (final game in _expansionsOf('a', 2))
                      _row(game.title, nested: true),
                ],
              ),
            ],
          ),
        ),
      );
    }
  });
}
