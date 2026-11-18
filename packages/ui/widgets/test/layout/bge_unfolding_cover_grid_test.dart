import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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

/// Whether the expansions badge [badge] finds draws its focus ring.
bool _ringShown(WidgetTester tester, Finder badge) {
  final ring = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.descendant(of: badge, matching: find.byType(BgeFocusRing)),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  return (ring.decoration as BoxDecoration).border != null;
}

void main() {
  const six = ['a', 'b', 'c', 'd', 'e', 'f'];

  group("the hand-off scope's lookup over the covers (#819)", () {
    // Two base games: b with the expansions x and y in its strip, c with
    // none.
    final isShown = BgeUnfoldingCovers.isShownIn(
      const [
        ('b', ['x', 'y']),
        ('c', <String>[]),
      ],
      idOf: (item) => item.$1,
      stripIdsOf: (item) => item.$2,
    );

    test('shows each cover at top level, under no place', () {
      expect(isShown('b', null), isTrue);
      expect(isShown('c', null), isTrue);
      expect(isShown('x', null), isFalse);
    });

    test("shows each strip's covers in its strip, folded or open", () {
      expect(isShown('x', BgeUnfoldingCovers.stripPlace('b')), isTrue);
      expect(isShown('y', BgeUnfoldingCovers.stripPlace('b')), isTrue);
      expect(isShown('x', BgeUnfoldingCovers.stripPlace('c')), isFalse);
    });

    test("a strip's place is no place a screen names itself", () {
      expect(
        BgeUnfoldingCovers.stripPlace('b'),
        BgeUnfoldingCovers.stripPlace('b'),
      );
      expect(BgeUnfoldingCovers.stripPlace('b'), isNot('b'));
      expect(isShown('x', 'b'), isFalse);
    });
  });

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

  testWidgets('a tile after the strip keeps its State and focus as the strip '
      'opens and closes (#820)', (tester) async {
    await tester.pumpWidget(hostAtSize(tester, _grid(six), size: _window));
    final finder = find.descendant(
      of: _tile('e'),
      matching: find.byType(_Tile),
    );
    final state = tester.state<_TileState>(finder);
    state.focusNode.requestFocus();
    await tester.pump();
    expect(state.focusNode.hasPrimaryFocus, isTrue);

    // e moves into the grid after a's strip, into the one before its own,
    // back after a's, and into the one grid again.
    for (final (step, unfolded) in [
      ("a's strip opened", 0),
      ('its own opened', 4),
      ("a's opened again", 0),
      ('closed', null),
    ]) {
      await tester.pumpWidget(
        hostAtSize(tester, _grid(six, unfolded: unfolded), size: _window),
      );
      await tester.pump();

      expect(tester.state<_TileState>(finder), same(state), reason: step);
      expect(state.focusNode.hasPrimaryFocus, isTrue, reason: step);
    }
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
            itemBuilder: (context, item, toggle, {required unfolded}) =>
                TextButton(
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

  group('an opened strip is scrolled into view (#818)', () {
    const names = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

    /// Two columns of 196dp covers 8dp apart, so the rows start at 0, 204,
    /// 408 and 612 in a 500dp view: c's row is the last one wholly in view,
    /// and a strip under it starts at 408, crossing the fold.
    const window = Size(400, 500);
    const stripHeight = 120.0;

    late ScrollController controller;

    setUp(() => controller = ScrollController());
    tearDown(() => controller.dispose());

    /// Covers that open their strips from their badges, as Games and
    /// Collection draw them. A strip is [stripHeight] tall, or as
    /// [stripHeights] says for its item.
    Widget covers({
      List<String> items = names,
      double stripHeight = stripHeight,
      Map<String, double> stripHeights = const {},
    }) => Scaffold(
      body: CustomScrollView(
        controller: controller,
        slivers: [
          BgeUnfoldingCovers<String>(
            items: items,
            keyOf: ValueKey.new,
            idOf: (name) => name,
            hasStrip: (_) => true,
            itemBuilder: (context, name, toggle, {required unfolded}) =>
                BgeCoverTile(
                  label: name,
                  extent: null,
                  onTap: () {},
                  expansions: BgeCoverExpansions(
                    count: 1,
                    expanded: unfolded,
                    onToggle: toggle,
                    label: '$name expansions, 1',
                    showLabel: 'Show expansions',
                    hideLabel: 'Hide expansions',
                  ),
                ),
            stripBuilder: (context, name) => SizedBox(
              key: _stripKey,
              height: stripHeights[name] ?? stripHeight,
              child: Text('strip of $name'),
            ),
          ),
        ],
      ),
    );

    /// Hosts [child] in [window], with the OS asking for reduced motion
    /// when [reduceMotion].
    Widget host(
      WidgetTester tester,
      Widget child, {
      bool reduceMotion = false,
    }) => hostAtSize(
      tester,
      child,
      size: window,
      builder: reduceMotion
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
    );

    Finder badge(String name) => find.descendant(
      of: _tile(name),
      matching: find.byKey(BgeCoverTile.expansionsBadgeKey),
    );
    Rect viewport(WidgetTester tester) =>
        tester.getRect(find.byType(CustomScrollView));
    Rect strip(WidgetTester tester) => tester.getRect(find.byKey(_stripKey));

    testWidgets('opening a strip on the last visible row scrolls it into '
        'view', (tester) async {
      await tester.pumpWidget(host(tester, covers()));

      await tester.tap(badge('c'));
      await tester.pump();
      expect(
        controller.position.isScrollingNotifier.value,
        isTrue,
        reason: 'it animates',
      );
      await tester.pumpAndSettle();

      // The shortest distance: the strip's bottom at the view's.
      expect(strip(tester).bottom, moreOrLessEquals(viewport(tester).bottom));
      expect(
        tester.getRect(_tile('c')).top,
        greaterThanOrEqualTo(viewport(tester).top),
      );
    });

    testWidgets('an open while another strip is open is revealed too', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(tester, covers(stripHeights: {'a': 40, 'c': 200})),
      );
      // a's strip, in view, pushes c's row down to 252..448, the last row
      // wholly in view. c's tile moves into the first grid as its own strip
      // opens.
      await tester.tap(badge('a'));
      await tester.pumpAndSettle();
      expect(controller.position.pixels, 0);

      await tester.tap(badge('c'));
      await tester.pumpAndSettle();

      expect(find.text('strip of c'), findsOneWidget);
      expect(strip(tester).bottom, moreOrLessEquals(viewport(tester).bottom));
      expect(
        tester.getRect(_tile('c')).top,
        greaterThanOrEqualTo(viewport(tester).top),
      );
    });

    testWidgets('an open that a strip above it, closing, moves above the '
        "view scrolls back to the tapped row's top", (tester) async {
      // Rows enough under e's that the page can't clamp as a's strip goes.
      await tester.pumpWidget(
        host(
          tester,
          covers(
            items: [...names, 'i', 'j', 'k', 'l', 'm', 'n'],
            stripHeights: {'a': 300},
          ),
        ),
      );
      await tester.tap(badge('a'));
      await tester.pumpAndSettle();
      // e's row, a row under c's and not built yet, about 50dp under the
      // view's top, its badge in view, and a's strip above it. c's row is
      // built, under the view's bottom.
      controller.jumpTo(
        controller.offset +
            tester
                .getRect(find.byKey(const ValueKey('c'), skipOffstage: false))
                .top +
            204 -
            viewport(tester).top -
            50,
      );
      await tester.pump();
      expect(
        tester.getRect(_tile('e')).top,
        inInclusiveRange(viewport(tester).top, viewport(tester).top + 100),
      );

      // a's strip folds as e's opens, and e's row moves up by its height,
      // out of the view, with the top of e's strip.
      await tester.tap(badge('e'));
      await tester.pump();
      expect(strip(tester).top, lessThan(viewport(tester).top));
      await tester.pumpAndSettle();

      expect(find.text('strip of a'), findsNothing);
      expect(find.text('strip of e'), findsOneWidget);
      expect(
        tester.getRect(_tile('e')).top,
        moreOrLessEquals(viewport(tester).top),
      );
      expect(strip(tester).bottom, lessThanOrEqualTo(viewport(tester).bottom));
    });

    testWidgets('with reduced motion the reveal jumps', (tester) async {
      await tester.pumpWidget(host(tester, covers(), reduceMotion: true));

      await tester.tap(badge('c'));
      await tester.pump();

      final position = controller.position;
      expect(position.isScrollingNotifier.value, isFalse);
      final jumped = position.pixels;
      expect(jumped, greaterThan(0));

      await tester.pumpAndSettle();
      expect(position.pixels, jumped, reason: 'nothing moves after the jump');
      expect(strip(tester).bottom, moreOrLessEquals(viewport(tester).bottom));
    });

    testWidgets("the reveal moves over the motion tokens' medium duration", (
      tester,
    ) async {
      await tester.pumpWidget(host(tester, covers()));
      final medium = BgeTokens.of(
        tester.element(find.byType(CustomScrollView)),
      ).motionMedium;
      // Well inside the gap to the short and long durations either side.
      const margin = Duration(milliseconds: 20);

      await tester.tap(badge('c'));
      // The frame that lays the strip out, which starts the reveal after
      // it, and the reveal's first tick, which starts its clock.
      await tester.pump();
      final position = controller.position;
      expect(position.isScrollingNotifier.value, isTrue);
      await tester.pump();

      await tester.pump(medium - margin);
      expect(
        position.isScrollingNotifier.value,
        isTrue,
        reason: 'still on its way',
      );
      final onItsWay = position.pixels;

      await tester.pump(margin * 2);
      expect(position.isScrollingNotifier.value, isFalse, reason: 'arrived');
      final arrived = position.pixels;
      expect(arrived, greaterThan(onItsWay));
      await tester.pumpAndSettle();
      expect(position.pixels, arrived, reason: 'nothing moves after it');
      expect(strip(tester).bottom, moreOrLessEquals(viewport(tester).bottom));
    });

    // At 100, c's row is at 104..300 and its strip ends at 428, in view.
    // Revealing its end would take the page back to 28.
    for (final (offset, name) in [(0.0, 'a'), (100.0, 'c')]) {
      testWidgets("opening a strip already in view doesn't scroll, at "
          '$offset', (tester) async {
        await tester.pumpWidget(host(tester, covers()));
        controller.jumpTo(offset);
        await tester.pump();

        await tester.tap(badge(name));
        await tester.pumpAndSettle();

        expect(find.text('strip of $name'), findsOneWidget);
        expect(controller.position.pixels, offset);
      });
    }

    for (final (why, close) in <(String, Future<void> Function(WidgetTester))>[
      ('its badge closes it', (tester) => tester.tap(badge('c'))),
      (
        'its item goes',
        (tester) async => tester.pumpWidget(
          host(tester, covers(items: [...names]..remove('c'))),
        ),
      ),
    ]) {
      testWidgets("a strip doesn't scroll as it closes: $why", (tester) async {
        await tester.pumpWidget(host(tester, covers()));
        await tester.tap(badge('c'));
        await tester.pumpAndSettle();
        // Back to the top, where revealing c's row or its strip would move
        // the page again.
        controller.jumpTo(0);
        await tester.pump();

        await close(tester);
        await tester.pumpAndSettle();

        expect(find.byKey(_stripKey), findsNothing);
        expect(controller.position.pixels, 0);
      });
    }

    testWidgets("a strip taller than the viewport keeps the tapped row's top "
        'in view', (tester) async {
      await tester.pumpWidget(host(tester, covers(stripHeight: 600)));

      await tester.tap(badge('c'));
      await tester.pumpAndSettle();

      // As far as it may go: c's row at the top, and the strip's top under
      // it.
      expect(
        tester.getRect(_tile('c')).top,
        moreOrLessEquals(viewport(tester).top),
      );
      expect(strip(tester).top, lessThan(viewport(tester).bottom));
    });

    /// Whether keyboard focus is on the badge of [name].
    bool badgeFocused(WidgetTester tester, String name) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      final target = tester.element(badge(name));
      var within = false;
      focused.visitAncestorElements((ancestor) {
        within = identical(ancestor, target);
        return !within;
      });
      return within;
    }

    /// Focuses the badge of [name] and opens its strip with Enter, as a
    /// keyboard user does.
    Future<void> pressBadge(WidgetTester tester, String name) async {
      tester
          .widget<Focus>(
            find
                .descendant(
                  of: badge(name),
                  matching: find.byWidgetPredicate(
                    (widget) => widget is Focus && widget.focusNode != null,
                  ),
                )
                .first,
          )
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    }

    for (final (how, ringed) in [
      ('from the keyboard', true),
      ('from a tap', false),
    ]) {
      testWidgets('focus stays on the badge, opened $how', (tester) async {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
        await tester.pumpWidget(host(tester, covers()));

        if (ringed) {
          await pressBadge(tester, 'c');
        } else {
          await tester.tap(badge('c'));
        }
        await tester.pump();
        expect(find.text('strip of c'), findsOneWidget);
        expect(badgeFocused(tester, 'c'), isTrue);
        expect(_ringShown(tester, badge('c')), ringed);

        await tester.pumpAndSettle();

        expect(controller.position.pixels, greaterThan(0));
        expect(badgeFocused(tester, 'c'), isTrue);
        expect(_ringShown(tester, badge('c')), ringed);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }

    for (final (why, close) in <(String, Future<void> Function(WidgetTester))>[
      (
        'Enter closes it',
        (tester) => tester.sendKeyEvent(LogicalKeyboardKey.enter),
      ),
      (
        'its item goes',
        (tester) => tester.pumpWidget(
          host(tester, covers(items: [...names]..remove('c'))),
        ),
      ),
      (
        'the covers go, as a switch to the list does',
        (tester) => tester.pumpWidget(
          host(
            tester,
            Scaffold(
              body: CustomScrollView(
                controller: controller,
                slivers: const [
                  SliverToBoxAdapter(child: SizedBox(height: 2000)),
                ],
              ),
            ),
          ),
        ),
      ),
    ]) {
      testWidgets('a reveal stops where it is as its strip goes: $why', (
        tester,
      ) async {
        await tester.pumpWidget(host(tester, covers()));
        await pressBadge(tester, 'c');
        // The strip's frame, then the animation's first, from which its
        // time counts, then 40ms of it.
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        final position = controller.position;
        expect(position.isScrollingNotifier.value, isTrue);
        final stopped = position.pixels;
        expect(stopped, inExclusiveRange(0, 28), reason: 'on its way to 28');

        await close(tester);
        await tester.pump();
        expect(find.byKey(_stripKey), findsNothing);
        await tester.pumpAndSettle();

        expect(position.pixels, stopped);
      });
    }

    testWidgets("Show expansions from the cover's custom action reveals the "
        'strip too', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(host(tester, covers()));
        final cover = tester.getSemantics(
          find.descendant(of: _tile('c'), matching: find.byType(BgeThumbnail)),
        );

        cover.owner!.performAction(
          cover.id,
          SemanticsAction.customAction,
          CustomSemanticsAction.getIdentifier(
            const CustomSemanticsAction(label: 'Show expansions'),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('strip of c'), findsOneWidget);
        expect(
          strip(tester).bottom,
          moreOrLessEquals(viewport(tester).bottom),
        );
      } finally {
        handle.dispose();
      }
    });
  });

  group('a tile keeps its element as another strip opens (#820)', () {
    // In [_window]: two columns, and room for every cover and a strip.
    const names = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

    /// Covers with expansions badges, each an item of its game in a focus
    /// hand-off scope, as Games and Collection draw them.
    Widget covers(List<String> items, {Key? key}) => BgeUnfoldingCovers<String>(
      key: key,
      items: items,
      keyOf: ValueKey.new,
      idOf: (name) => name,
      hasStrip: (_) => true,
      itemBuilder: (context, name, toggle, {required unfolded}) =>
          BgeFocusHandoff(
            identity: name,
            child: BgeCoverTile(
              label: name,
              extent: null,
              onTap: () {},
              expansions: BgeCoverExpansions(
                count: 1,
                expanded: unfolded,
                onToggle: toggle,
                label: '$name expansions, 1',
                showLabel: 'Show expansions',
                hideLabel: 'Hide expansions',
              ),
            ),
          ),
      stripBuilder: (context, name) => SizedBox(
        key: _stripKey,
        height: _stripHeight,
        child: Text('strip of $name'),
      ),
    );

    Widget page(List<Widget> slivers) => Scaffold(
      body: BgeFocusHandoffScope(child: CustomScrollView(slivers: slivers)),
    );

    Finder badge(String name, {Finder? within}) => find.descendant(
      of: within == null
          ? _tile(name)
          : find.descendant(of: within, matching: _tile(name)),
      matching: find.byKey(BgeCoverTile.expansionsBadgeKey),
    );

    /// The focus node of the badge of [name].
    FocusNode badgeNode(WidgetTester tester, String name) => tester
        .widget<Focus>(
          find
              .descendant(
                of: badge(name),
                matching: find.byWidgetPredicate(
                  (widget) => widget is Focus && widget.focusNode != null,
                ),
              )
              .first,
        )
        .focusNode!;

    /// Every node that takes primary focus from now on, until the test
    /// ends.
    List<FocusNode?> focusChanges() {
      final changes = <FocusNode?>[];
      void listener() => changes.add(FocusManager.instance.primaryFocus);
      FocusManager.instance.addListener(listener);
      addTearDown(() => FocusManager.instance.removeListener(listener));
      return changes;
    }

    testWidgets("with a strip open, opening a later item's strip keeps the "
        "tapped badge's semantics node", (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          hostAtSize(tester, page([covers(names)]), size: _window),
        );
        // As PR #809 measured it: a's strip, then the badge of a game in the
        // grid after it. Two columns, so e opens under the third row, and
        // moves into the grid before its own strip.
        await tester.tap(badge('a'));
        await tester.pumpAndSettle();
        SemanticsNode cover() => tester.getSemantics(
          find.descendant(of: _tile('e'), matching: find.byType(BgeThumbnail)),
        );
        final badgeBefore = tester.getSemantics(badge('e')).id;
        final coverBefore = cover().id;

        await tester.tap(badge('e'));
        await tester.pumpAndSettle();

        expect(find.text('strip of e'), findsOneWidget);
        expect(tester.getSemantics(badge('e')).id, badgeBefore);
        expect(cover().id, coverBefore);
      } finally {
        handle.dispose();
      }
    });

    // A pointer's kind, or null for the keyboard's Enter.
    for (final (how, kind) in <(String, PointerDeviceKind?)>[
      ('from the keyboard', null),
      ('from a click', PointerDeviceKind.mouse),
      ('from a tap', PointerDeviceKind.touch),
    ]) {
      testWidgets('the badge keeps its focus node as its tile moves, with no '
          'hand-off, opened $how', (tester) async {
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic;
        await tester.pumpWidget(
          hostAtSize(tester, page([covers(names)]), size: _window),
        );
        await tester.tap(badge('a'));
        await tester.pumpAndSettle();
        final node = badgeNode(tester, 'e');
        if (kind == null) {
          node.requestFocus();
          await tester.pump();
        }
        final changes = focusChanges();

        if (kind == null) {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          await tester.tap(badge('e'), kind: kind);
        }
        // Only the keyboard's focus draws the ring: a click's is a pointer's
        // (BgePointerFocus), which the tile keeps as it moves, and a tap
        // leaves the touch highlight mode on.
        final ringed = kind == null;
        // Frame by frame: focus never leaves the badge, which keeps its
        // ring, or its lack of one, throughout.
        for (var frame = 0; frame < 4; frame += 1) {
          await tester.pump();
          expect(find.text('strip of e'), findsOneWidget);
          expect(badgeNode(tester, 'e'), same(node), reason: 'frame $frame');
          expect(node.hasPrimaryFocus, isTrue, reason: 'frame $frame');
          expect(
            _ringShown(tester, badge('e')),
            ringed,
            reason: 'frame $frame',
          );
        }
        await tester.pumpAndSettle();

        expect(node.hasPrimaryFocus, isTrue);
        expect(_ringShown(tester, badge('e')), ringed);
        // A pointer's own focus, and nothing after it.
        expect(changes, kind == null ? isEmpty : [node]);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }

    for (final (what, route) in <(String, Route<void> Function(BuildContext))>[
      (
        'a pop-up',
        (context) => DialogRoute(
          context: context,
          builder: (context) => const Dialog(child: Text('above')),
        ),
      ),
      (
        'a page',
        (context) => MaterialPageRoute(
          builder: (context) => const Scaffold(body: Text('above')),
        ),
      ),
    ]) {
      testWidgets('a badge the page gives focus back to keeps it as its tile '
          'moves under $what', (tester) async {
        final items = ValueNotifier(names);
        addTearDown(items.dispose);
        await tester.pumpWidget(
          hostAtSize(
            tester,
            ValueListenableBuilder(
              valueListenable: items,
              builder: (context, items, _) => page([covers(items)]),
            ),
            size: _window,
          ),
        );
        await tester.tap(badge('a'));
        await tester.pumpAndSettle();
        final node = badgeNode(tester, 'e')..requestFocus();
        await tester.pump();

        final context = tester.element(find.byType(CustomScrollView));
        final navigator = Navigator.of(context)..push(route(context));
        await tester.pumpAndSettle();
        expect(node.hasFocus, isFalse);

        // a moves to the third row, and e into the grid before a's strip.
        // Covered, the page still builds, and lays out what changed, so e's
        // tile moves under the route.
        items.value = ['b', 'c', 'd', 'e', 'a', 'f', 'g', 'h'];
        await tester.pumpAndSettle();
        // Still mounted: kept, not built again.
        expect(node.context?.mounted, isTrue);
        final changes = focusChanges();

        navigator.pop();
        await tester.pumpAndSettle();

        expect(badgeNode(tester, 'e'), same(node));
        expect(node.hasPrimaryFocus, isTrue);
        // The pop's own, and no hand-off after it.
        expect(changes, [node]);
      });
    }

    testWidgets('two grids over the same items build together', (
      tester,
    ) async {
      const first = Key('first');
      const second = Key('second');
      const four = ['a', 'b', 'c', 'd'];
      await tester.pumpWidget(
        hostAtSize(
          tester,
          page([
            covers(four, key: first),
            covers(four, key: second),
          ]),
          size: _window,
        ),
      );

      // A strip open in each, and then a later one, so the same items'
      // tiles move between the grids of both at once.
      for (final name in ['a', 'c']) {
        for (final grid in [first, second]) {
          await tester.tap(badge(name, within: find.byKey(grid)));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(find.text('strip of $name'), findsNWidgets(2));
      }
    });

    group('an item that leaves takes its key with it', () {
      Finder tileOf(String name) =>
          find.descendant(of: _tile(name), matching: find.byType(_Tile));

      /// The global key the grid holds [name]'s tile under.
      Key tileKey(WidgetTester tester, String name) => tester
          .widget<KeyedSubtree>(
            find.descendant(
              of: _tile(name),
              matching: find.byWidgetPredicate(
                (widget) => widget is KeyedSubtree && widget.key is GlobalKey,
              ),
            ),
          )
          .key!;

      /// Shows [six] with c's strip open, takes c away, and brings it back.
      Future<void> leaveAndReturn(
        WidgetTester tester, {
        required void Function() before,
      }) async {
        await tester.pumpWidget(
          hostAtSize(tester, _grid(six, unfolded: 2), size: _window),
        );
        before();
        await tester.pumpWidget(
          hostAtSize(
            tester,
            _grid([
              for (final name in six)
                if (name == 'c') 'x' else name,
            ]),
            size: _window,
          ),
        );
        expect(_tile('c'), findsNothing);
        await tester.pumpWidget(
          hostAtSize(tester, _grid(six), size: _window),
        );
      }

      testWidgets('so it comes back as a new tile, under a new key', (
        tester,
      ) async {
        late _TileState state;
        late Key key;
        await leaveAndReturn(
          tester,
          before: () {
            state = tester.state<_TileState>(tileOf('c'));
            key = tileKey(tester, 'c');
          },
        );

        expect(tester.state<_TileState>(tileOf('c')), isNot(same(state)));
        expect(tileKey(tester, 'c'), isNot(same(key)));
      });

      testWidgets('and the tiles beside it keep their State and key', (
        tester,
      ) async {
        final states = <String, _TileState>{};
        final keys = <String, Key>{};
        await leaveAndReturn(
          tester,
          before: () {
            for (final name in ['b', 'd']) {
              states[name] = tester.state<_TileState>(tileOf(name));
              keys[name] = tileKey(tester, name);
            }
          },
        );

        for (final name in ['b', 'd']) {
          expect(
            tester.state<_TileState>(tileOf(name)),
            same(states[name]),
            reason: name,
          );
          expect(tileKey(tester, name), same(keys[name]), reason: name);
        }
      });
    });

    group('two items under one key', () {
      const twice = ['a', 'b', 'a', 'c'];

      /// Every error [pump] reports, in order, up to the tree's teardown:
      /// the first is the one a developer reads first.
      Future<List<Object>> errorsOf(
        WidgetTester tester,
        Future<void> Function() pump,
      ) async {
        final errors = <Object>[];
        final onError = FlutterError.onError;
        FlutterError.onError = (details) => errors.add(details.exception);
        try {
          await pump();
          await tester.pumpWidget(const SizedBox());
        } finally {
          FlutterError.onError = onError;
        }
        return errors;
      }

      void expectNamed(List<Object> errors) => expect(
        errors.first,
        isA<AssertionError>().having(
          (error) => error.message,
          'message',
          contains('two items have the key'),
        ),
      );

      testWidgets('are named as the cause when the grid is built', (
        tester,
      ) async {
        final errors = await errorsOf(
          tester,
          () => tester.pumpWidget(
            hostAtSize(tester, _grid(twice), size: _window),
          ),
        );

        expectNamed(errors);
        expect(errors, hasLength(1));
      });

      // A state that throws as it updates leaves the framework an assertion
      // of its own to report as the tree is torn down, after this one.
      testWidgets('are named as the cause when the items change', (
        tester,
      ) async {
        await tester.pumpWidget(hostAtSize(tester, _grid(six), size: _window));

        final errors = await errorsOf(
          tester,
          () => tester.pumpWidget(
            hostAtSize(tester, _grid(twice), size: _window),
          ),
        );

        expectNamed(errors);
      });
    });
  });
}
