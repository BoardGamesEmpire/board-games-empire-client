import 'dart:ui' show AppLifecycleState, Tristate;

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, precisionErrorTolerance;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _gameCount = 30;
const _label = 'Wingspan expansions';

/// The page's own count: its games, and the box as one more item.
const int _pageCount = _gameCount + 1;

const _phone = Size(400, 600);
const _narrowPortrait = Size(320, 568);
const _narrowLandscape = Size(568, 320);

/// Tall enough that half the page's viewport is more than 3½ rows, so the
/// rows alone decide the box's height.
const _tall = Size(400, 1400);

Key _gameKey(int index) => ValueKey('game.$index');
Key _expansionKey(int id) => ValueKey('expansion.$id');

/// A row as the list screens build one: outlined, merged into one node,
/// ringed and tappable, and indented under its base game when [nested]. An
/// [inert] one has no tap, as a list's rows have where nothing can be opened,
/// and so is no focus stop.
Widget _tile(
  String title, {
  required Key key,
  bool nested = false,
  bool inert = false,
  bool focusOnTap = false,
}) => Padding(
  key: key,
  padding: EdgeInsetsDirectional.only(
    start: nested ? BgeTokens.spaceLgValue : 0,
  ),
  child: BgeOutlinedRow(
    child: MergeSemantics(
      child: BgeRowFocusRing(
        focusOnTap: focusOnTap,
        builder: (_, row) => ListTile(
          focusNode: row.focusNode,
          onFocusChange: row.onFocusChange,
          focusColor: row.focusColor,
          onTap: row.onTap(inert ? null : () {}),
          title: Text(title),
          subtitle: const Text('2 to 4 players'),
        ),
      ),
    ),
  ),
);

/// The rows of a base game with [count] expansions, or with those in [ids].
List<Widget> _expansions({
  int count = 8,
  List<int>? ids,
  bool inert = false,
  bool focusOnTap = false,
}) => [
  for (final id in ids ?? [for (var i = 0; i < count; i++) i])
    _tile(
      'Expansion $id',
      key: _expansionKey(id),
      nested: true,
      inert: inert,
      focusOnTap: focusOnTap,
    ),
];

/// The height of a [_tallRows] row: more than twice any box these tests
/// build.
const double _tallRow = 700;

/// Rows of one stop each, each far taller than the box. An [inert] one has
/// no tap, and so no stop.
List<Widget> _tallRows({bool inert = false}) => [
  for (var i = 0; i < 6; i++)
    SizedBox(
      key: _expansionKey(i),
      height: _tallRow,
      child: InkWell(
        onTap: inert ? null : () {},
        child: Text('Expansion $i'),
      ),
    ),
];

/// Rows of the given heights and nothing else, for measuring the box.
List<Widget> _sized(List<double> heights) => [
  for (final (id, height) in heights.indexed)
    SizedBox(
      key: _expansionKey(id),
      height: height,
      child: Text('Expansion $id'),
    ),
];

Widget _box({
  List<Widget>? rows,
  ScrollController? controller,
  bool focusable = false,
}) => BgeNestedRowsBox(
  semanticLabel: _label,
  controller: controller,
  focusable: focusable,
  rows: rows ?? _expansions(),
);

/// A box of rows that take no focus, which is what [focusable] is for.
Widget _inertBox({bool focusable = true, int count = 8}) => _box(
  rows: _expansions(count: count, inert: true),
  focusable: focusable,
);

/// A list page of [_gameCount] games with [box] under the game at [boxAfter].
Widget _page({
  Widget? box,
  int boxAfter = 0,
  ScrollController? controller,
  Widget? footer,
  Future<void> Function()? onRefresh,
}) => BgePage.slivers(
  title: const Text('Games'),
  width: BgePageWidth.pane,
  semanticChildCount: _pageCount,
  scrollController: controller,
  footer: footer,
  onRefresh: onRefresh,
  slivers: [
    SliverList.list(
      children: [
        for (var i = 0; i < _gameCount; i++) ...[
          _tile('Game $i', key: _gameKey(i)),
          if (i == boxAfter && box != null) box,
        ],
      ],
    ),
  ],
);

Widget _app(
  Widget home, {
  double textScale = 1,
  TargetPlatform? platform,
  TextDirection direction = TextDirection.ltr,
  ThemeData? theme,
  Map<ShortcutActivator, Intent>? shortcuts,
}) => MaterialApp(
  shortcuts: shortcuts,
  // The shipped themes are cached with the platform they were first built
  // on, so a platform variant has to say its own.
  theme: (theme ?? BgeTheme.light()).copyWith(
    platform: platform ?? defaultTargetPlatform,
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: Directionality(textDirection: direction, child: child!),
  ),
  home: home,
);

Finder get _theBox => find.byType(BgeNestedRowsBox);

/// The box's own scroll view: the first in it, ahead of any a row holds.
Finder get _theRows =>
    find.descendant(of: _theBox, matching: find.byType(Scrollable)).first;

/// The box's own scroll position.
ScrollPosition _inner(WidgetTester tester) =>
    tester.state<ScrollableState>(_theRows).position;

/// The page's scroll position.
ScrollPosition _outer(WidgetTester tester) => pageScrollOf(tester).position;

/// The part of the box its rows show in: all of it but the gap under them.
Rect _rowsRect(WidgetTester tester) => tester.getRect(_theRows);

/// The box's own viewport: the first render object under its scroll view
/// that is one.
RenderBox _viewport(WidgetTester tester) {
  RenderBox? found;
  void visit(RenderObject object) {
    if (found != null) return;
    if (object is RenderBox && object is RenderAbstractViewport) {
      found = object;
      return;
    }
    object.visitChildren(visit);
  }

  visit(tester.renderObject(_theRows));
  return found!;
}

/// Whether [node] is inside the box.
bool _inTheBox(WidgetTester tester, FocusNode? node) {
  final box = tester.element(_theBox);
  var inside = false;
  node?.context?.visitAncestorElements((element) {
    inside = element == box;
    return !inside;
  });
  return inside;
}

/// The painter of the box's scrollbar. There is one, whatever draws it.
ScrollbarPainter _bar(WidgetTester tester) => tester
    .widgetList<CustomPaint>(
      find.descendant(of: _theBox, matching: find.byType(CustomPaint)),
    )
    .map((paint) => paint.foregroundPainter)
    .whereType<ScrollbarPainter>()
    .single;

/// The box's own focus stop: the nearest above its scroll view.
FocusNode _boxFocus(WidgetTester tester) => Focus.of(tester.element(_theRows));

/// Whether the box's own focus ring is drawn: something painted in the
/// theme's `primary` round the whole of the box's ring, as its outline, and
/// not a ring of a row inside it, which is smaller.
///
/// Read from what is painted, not from how the ring is built.
bool _ringShown(WidgetTester tester) {
  final ring = find
      .descendant(of: _theBox, matching: find.byType(BgeFocusRing))
      .first;
  final size = tester.getSize(ring);
  final primary = Theme.of(tester.element(ring)).colorScheme.primary;
  final stroke = BgeTokens.standard.focusOutlineWidth;
  bool roundTheRing(Rect outline) =>
      (outline.width - size.width).abs() <= 2 * stroke &&
      (outline.height - size.height).abs() <= 2 * stroke;

  var drawn = false;
  expect(
    tester.renderObject(ring),
    paints..everything((method, arguments) {
      final inPrimary = arguments.any(
        (argument) =>
            argument is Paint &&
            argument.color.toARGB32() == primary.toARGB32(),
      );
      final outline = arguments.any(
        (argument) =>
            (argument is RRect && roundTheRing(argument.outerRect)) ||
            (argument is Rect && roundTheRing(argument)),
      );
      if (inPrimary && outline) drawn = true;
      return true;
    }),
  );
  return drawn;
}

/// The four themes the app ships.
final Map<String, ThemeData Function()> _themes = {
  'light': BgeTheme.light,
  'dark': BgeTheme.dark,
  'high-contrast light': BgeTheme.highContrastLight,
  'high-contrast dark': BgeTheme.highContrastDark,
};

/// Every surface role a theme may put under the box.
List<Color> _surfacesOf(ThemeData theme) => [
  theme.scaffoldBackgroundColor,
  theme.colorScheme.surface,
  theme.colorScheme.surfaceContainerLowest,
  theme.colorScheme.surfaceContainerLow,
  theme.colorScheme.surfaceContainer,
  theme.colorScheme.surfaceContainerHigh,
  theme.colorScheme.surfaceContainerHighest,
];

/// What the page shows of itself: its viewport, on screen.
Rect _pageRect(WidgetTester tester) =>
    tester.getRect(find.byType(Scrollable).first);

/// The top of expansion [id]'s row plus half its height, from the box's top:
/// the height of a box that shows that row's top half and all before it.
double _halfwayDown(WidgetTester tester, int id) {
  final row = tester.getRect(find.byKey(_expansionKey(id)));
  return row.top - tester.getRect(_theBox).top + row.height / 2;
}

Future<void> _tab(WidgetTester tester, {bool back = false}) async {
  if (back) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (back) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
  // One frame and no more: the reveal is a jump, so it has landed by now.
  await tester.pump();
}

FocusNode _focusOf(WidgetTester tester, String title) =>
    Focus.of(tester.element(find.text(title)));

/// The title of the row that has focus, or null when none has.
String? _focusedTitle(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final title = text.data;
    if (title == null) continue;
    if (!title.startsWith('Game ') && !title.startsWith('Expansion ')) {
      continue;
    }
    if (_focusOf(tester, title).hasPrimaryFocus) return title;
  }
  return null;
}

/// Whether [inner] lies inside [outer], give or take a rounding error.
bool _within(Rect inner, Rect outer) =>
    inner.top >= outer.top - precisionErrorTolerance &&
    inner.bottom <= outer.bottom + precisionErrorTolerance;

SemanticsNode _semanticsRoot(WidgetTester tester) {
  SemanticsNode? root;
  tester.binding.rootPipelineOwner.visitChildren((owner) {
    root ??= owner.semanticsOwner?.rootSemanticsNode;
  });
  return root!;
}

/// The first node at or under [from] that [test] accepts, depth first.
SemanticsNode? _firstNode(
  SemanticsNode from,
  bool Function(SemanticsNode node) test,
) {
  if (test(from)) return from;
  SemanticsNode? found;
  from.visitChildren((child) {
    found = _firstNode(child, test);
    return found == null;
  });
  return found;
}

List<SemanticsNode> _childrenOf(SemanticsNode node) {
  final children = <SemanticsNode>[];
  node.visitChildren((child) {
    children.add(child);
    return true;
  });
  return children;
}

/// The node named [_label]: the box's group.
SemanticsNode _groupNode(WidgetTester tester) =>
    _firstNode(_semanticsRoot(tester), (node) => node.label == _label)!;

/// The node inside the box's group that carries its rows' count.
SemanticsNode _innerListNode(WidgetTester tester) =>
    _firstNode(_groupNode(tester), (node) => node.scrollChildCount != null)!;

void main() {
  group('BgeNestedRowsBox', () {
    group('height', () {
      testWidgets('height is 3½ rows on the first frame', (tester) async {
        useViewSize(tester, _tall);
        // Uneven, so only the rows as laid out give the answer.
        await tester.pumpWidget(
          _app(_page(box: _box(rows: _sized([40, 70, 50, 90, 60, 60, 60])))),
        );

        // 40 + 70 + 50, and half of 90.
        expect(tester.getSize(_theBox).height, 205);
        expect(tester.getSize(_theBox).height, _halfwayDown(tester, 3));

        // And it stays: nothing was waiting on a second frame.
        await tester.pump();
        expect(tester.getSize(_theBox).height, 205);
        await tester.pumpAndSettle();
        expect(tester.getSize(_theBox).height, 205);
        // All 430 of the rows scroll through what the gap leaves of the box.
        expect(
          _inner(tester).maxScrollExtent,
          430 - (205 - BgeTokens.standard.spaceSm),
        );
      });

      testWidgets('the last spaceSm of the box is a gap under its rows, as '
          'under an outlined row', (tester) async {
        useViewSize(tester, _tall);
        await tester.pumpWidget(_app(_page(box: _box())));
        await tester.pumpAndSettle();

        final box = tester.getRect(_theBox);
        expect(box.height, _halfwayDown(tester, 3));
        expect(
          _rowsRect(tester).bottom,
          box.bottom - BgeTokens.standard.spaceSm,
        );
        // The next row starts where the box ends, clear of the row cut short.
        expect(tester.getRect(find.byKey(_gameKey(1))).top, box.bottom);
      });

      testWidgets('a fifth row arriving caps the rows, and its leaving shows '
          'them all again', (tester) async {
        useViewSize(tester, _tall);
        Widget app(int count) =>
            _app(_page(box: _box(rows: _sized(List.filled(count, 60)))));
        await tester.pumpWidget(app(4));
        expect(tester.getSize(_theBox).height, 240);

        await tester.pumpWidget(app(5));
        expect(tester.getSize(_theBox).height, 210);
        expect(_inner(tester).maxScrollExtent, greaterThan(0));

        await tester.pumpWidget(app(4));
        expect(tester.getSize(_theBox).height, 240);
        expect(_inner(tester).maxScrollExtent, 0);
      });

      testWidgets('3½ of its own rows at 320 dp × 2.0, with nothing '
          'overflowing', (tester) async {
        // Tall enough for the rows to decide.
        useViewSize(tester, const Size(320, 4000));
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));

        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(_theBox).height,
          moreOrLessEquals(_halfwayDown(tester, 3)),
        );
      });

      testWidgets('capped to half the viewport in landscape at 2.0', (
        tester,
      ) async {
        useViewSize(tester, _narrowLandscape);
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));

        // On the first frame.
        final viewport = _outer(tester).viewportDimension;
        expect(tester.getSize(_theBox).height, viewport / 2);
        // The cap, not the rows, decided.
        expect(_halfwayDown(tester, 3), greaterThan(viewport / 2));

        await tester.pumpAndSettle();
        expect(tester.getSize(_theBox).height, viewport / 2);
        expect(_inner(tester).maxScrollExtent, greaterThan(0));

        // The page can still be dragged, from what the box leaves of it.
        expect(_outer(tester).pixels, 0);
        await tester.drag(find.byKey(_gameKey(0)), const Offset(0, -60));
        await tester.pumpAndSettle();
        expect(_outer(tester).pixels, greaterThan(0));
        expect(_inner(tester).pixels, 0);
      });

      testWidgets('capped to half the viewport at 320 × 568 at 2.0', (
        tester,
      ) async {
        useViewSize(tester, _narrowPortrait);
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));

        final viewport = _outer(tester).viewportDimension;
        expect(tester.getSize(_theBox).height, viewport / 2);
        expect(_halfwayDown(tester, 3), greaterThan(viewport / 2));
      });

      testWidgets('the cap follows the page when its viewport gets shorter '
          'and nothing else changes', (tester) async {
        // The width stays, so nothing lays the box out again for it.
        useViewSize(tester, const Size(568, 600));
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));
        await tester.pumpAndSettle();
        final before = _outer(tester).viewportDimension;
        expect(tester.getSize(_theBox).height, before / 2);

        tester.view.physicalSize = _narrowLandscape;
        // The frame that shortens the page, then the frame that follows it.
        await tester.pump();
        await tester.pump();

        final after = _outer(tester).viewportDimension;
        expect(after, lessThan(before));
        expect(tester.getSize(_theBox).height, after / 2);
      });

      testWidgets('scrolled out of a lazy list as the page jumps past it, it '
          'asks nothing of its viewport while it goes', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box())));
        await tester.pumpAndSettle();
        final page = _outer(tester);

        // The jump lays the list out past its cache, which drops the box,
        // and the page's new extent starts a scroll in that same layout.
        for (var i = 0; i < 5; i++) {
          page.jumpTo(page.maxScrollExtent);
          await tester.pump();
        }

        expect(
          find.byType(BgeNestedRowsBox, skipOffstage: false),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('moved in the tree within a frame, it goes on following '
          'the page', (tester) async {
        final key = GlobalKey();
        useViewSize(tester, _narrowLandscape);
        // The same box, under one more widget or one fewer: taken out of
        // the tree and put back in the one frame.
        Widget app({required bool wrapped, double footerHeight = 0}) {
          final box = BgeNestedRowsBox(
            key: key,
            semanticLabel: _label,
            rows: _expansions(),
          );
          return _app(
            _page(
              box: wrapped
                  ? Padding(padding: EdgeInsets.zero, child: box)
                  : box,
              footer: SizedBox(height: footerHeight),
            ),
            textScale: 2,
          );
        }

        await tester.pumpWidget(app(wrapped: false));
        await tester.pumpAndSettle();
        final state = tester.state(_theBox);
        await tester.pumpWidget(app(wrapped: true));
        await tester.pumpAndSettle();
        expect(tester.state(_theBox), same(state));
        final before = _outer(tester).viewportDimension;
        expect(tester.getSize(_theBox).height, before / 2);

        await tester.pumpWidget(app(wrapped: true, footerHeight: 80));
        await tester.pump();

        final after = _outer(tester).viewportDimension;
        expect(after, before - 80);
        expect(tester.getSize(_theBox).height, after / 2);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the cap follows the page when a footer takes room from '
          'it', (tester) async {
        useViewSize(tester, _narrowLandscape);
        Widget app(double footerHeight) => _app(
          _page(
            box: _box(),
            footer: SizedBox(height: footerHeight),
          ),
          textScale: 2,
        );
        await tester.pumpWidget(app(0));
        await tester.pumpAndSettle();
        final before = _outer(tester).viewportDimension;
        expect(tester.getSize(_theBox).height, before / 2);

        await tester.pumpWidget(app(80));
        await tester.pump();

        final after = _outer(tester).viewportDimension;
        expect(after, before - 80);
        expect(tester.getSize(_theBox).height, after / 2);
      });

      testWidgets('with inlineLimit rows it shows them all, and neither '
          'scrolls nor keeps room for a bar', (tester) async {
        expect(BgeNestedRowsBox.inlineLimit, 4);

        // Where five rows would be capped.
        useViewSize(tester, _narrowLandscape);
        await tester.pumpWidget(
          _app(
            _page(box: _box(rows: _expansions(count: 4))),
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();

        final box = tester.getRect(_theBox);
        final first = tester.getRect(find.byKey(_expansionKey(0)));
        final last = tester.getRect(find.byKey(_expansionKey(3)));
        expect(box.height, last.bottom - first.top);
        expect(box.height, greaterThan(_outer(tester).viewportDimension / 2));
        expect(_inner(tester).maxScrollExtent, 0);
        expect(last.right, box.right);
      });

      testWidgets('outside any scroll view it is 3½ rows', (tester) async {
        useViewSize(tester, _narrowLandscape);
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: _box(rows: _sized([40, 70, 50, 90, 60, 60, 60])),
              ),
            ),
          ),
        );

        // More than half the window: nothing here needs room to be dragged.
        expect(tester.getSize(_theBox).height, 205);
      });

      testWidgets('on a page that is one scroll view, not slivers, the cap '
          'comes a frame late', (tester) async {
        useViewSize(tester, _narrowLandscape);
        // Such a page lays its child out before it knows its own height.
        await tester.pumpWidget(
          _app(
            BgePage(
              title: const Text('Games'),
              child: Column(
                children: [
                  _tile('Game 0', key: _gameKey(0)),
                  _box(),
                  for (var i = 1; i < 8; i++)
                    _tile('Game $i', key: _gameKey(i)),
                ],
              ),
            ),
            textScale: 2,
          ),
        );
        // Its first frame: 3½ rows, with nothing yet to cap them by.
        expect(tester.getSize(_theBox).height, _halfwayDown(tester, 3));

        await tester.pump();

        final viewport = _outer(tester).viewportDimension;
        expect(_halfwayDown(tester, 3), greaterThan(viewport / 2));
        expect(tester.getSize(_theBox).height, viewport / 2);
      });

      testWidgets('as wide as its rows ask to be, where something asks', (
        tester,
      ) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(
            Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: IntrinsicWidth(
                  child: _box(
                    rows: [
                      for (var i = 0; i < 6; i++)
                        const SizedBox(width: 120, height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        // The rows, and the room they leave the bar.
        expect(
          tester.getSize(_theBox).width,
          120 + BgeTokens.standard.spaceMd,
        );
      });

      testWidgets('says why it has no dry layout', (tester) async {
        useViewSize(tester, _tall);
        await tester.pumpWidget(_app(_page(box: _box())));

        expect(
          () => _viewport(tester).getDryLayout(const BoxConstraints()),
          throwsA(
            isA<FlutterError>().having(
              (error) => error.toString(),
              'what it says',
              contains('where its rows land'),
            ),
          ),
        );
      });
    });

    group('scrolling', () {
      testWidgets('wheel at the inner edge scrolls the page', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();
        final inner = _inner(tester);
        final outer = _outer(tester);
        final wheel = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(
          wheel.hover(tester.getCenter(_theBox)),
        );

        // With rows left to show, the box takes it.
        await tester.sendEventToBinding(wheel.scroll(const Offset(0, 40)));
        await tester.pumpAndSettle();
        expect(inner.pixels, 40);
        expect(outer.pixels, 0);

        // At its end, the page does.
        inner.jumpTo(inner.maxScrollExtent);
        await tester.pumpAndSettle();
        await tester.sendEventToBinding(wheel.scroll(const Offset(0, 50)));
        await tester.pumpAndSettle();
        expect(inner.pixels, inner.maxScrollExtent);
        expect(outer.pixels, 50);

        // And at its start, the other way.
        inner.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.sendEventToBinding(
          wheel.hover(tester.getCenter(_theBox)),
        );
        await tester.sendEventToBinding(wheel.scroll(const Offset(0, -30)));
        await tester.pumpAndSettle();
        expect(inner.pixels, 0);
        expect(outer.pixels, 20);
      }, variant: TargetPlatformVariant.all());

      testWidgets('one scrollbar, always shown, drawing its thumb at rest '
          'with no scroll and no hover', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();

        // A desktop platform gives every scroll view a bar of its own, and
        // Material hands an iOS one to Cupertino: one bar all the same.
        final bars = find.descendant(
          of: _theBox,
          matching: find.byWidgetPredicate((widget) => widget is RawScrollbar),
        );
        expect(bars, findsOneWidget);
        expect(tester.widget<RawScrollbar>(bars).thumbVisibility, isTrue);
        expect(_inner(tester).maxScrollExtent, greaterThan(0));
        expect(bars, paints..rrect(color: _bar(tester).color));
      }, variant: TargetPlatformVariant.all());

      for (final MapEntry(key: name, value: theme) in _themes.entries) {
        testWidgets('the thumb stands 3:1 clear of the page at rest — $name', (
          tester,
        ) async {
          final data = theme();
          useViewSize(tester, _phone);
          await tester.pumpWidget(
            _app(_page(box: _box(), boxAfter: 2), theme: data),
          );
          await tester.pumpAndSettle();

          final thumb = _bar(tester).color;
          for (final ground in _surfacesOf(data)) {
            expect(
              Wcag.contrastRatio(Color.alphaBlend(thumb, ground), ground),
              greaterThanOrEqualTo(Wcag.aaNonText),
              reason: 'the thumb $thumb on $ground',
            );
          }
        }, variant: TargetPlatformVariant.all());

        testWidgets('the thumb stands 3:1 clear of the page under a mouse — '
            '$name', (tester) async {
          final data = theme();
          useViewSize(tester, _phone);
          await tester.pumpWidget(
            _app(_page(box: _box(), boxAfter: 2), theme: data),
          );
          await tester.pumpAndSettle();
          final atRest = _bar(tester).color;
          final box = tester.getRect(_theBox);

          final mouse = TestPointer(1, PointerDeviceKind.mouse);
          await tester.sendEventToBinding(
            mouse.hover(
              Offset(
                box.right - BgeTokens.standard.spaceSm,
                box.top + BgeTokens.standard.spaceLg,
              ),
            ),
          );
          await tester.pumpAndSettle();

          final hovered = _bar(tester).color;
          expect(hovered, isNot(atRest), reason: 'the thumb answers a hover');
          for (final ground in _surfacesOf(data)) {
            expect(
              Wcag.contrastRatio(Color.alphaBlend(hovered, ground), ground),
              greaterThanOrEqualTo(Wcag.aaNonText),
              reason: 'the hovered thumb $hovered on $ground',
            );
          }
        }, variant: TargetPlatformVariant.desktop());
      }

      testWidgets("the thumb keeps clear of where the box's focus ring is "
          'drawn', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();

        const tokens = BgeTokens.standard;
        final clear = tokens.focusOutlineWidth + tokens.focusRingGap;
        final bar = _bar(tester);
        expect(bar.crossAxisMargin, clear);
        expect(bar.mainAxisMargin, clear);
        // And inside the room the rows leave it.
        expect(bar.thickness + 2 * clear, lessThanOrEqualTo(tokens.spaceMd));
      }, variant: TargetPlatformVariant.all());

      for (final direction in TextDirection.values) {
        testWidgets('the rows leave the bar room of its own at their end — '
            '${direction.name}', (tester) async {
          useViewSize(tester, _phone);
          await tester.pumpWidget(
            _app(_page(box: _box(), boxAfter: 2), direction: direction),
          );
          await tester.pumpAndSettle();

          final box = tester.getRect(_theBox);
          final row = tester.getRect(find.byKey(_expansionKey(0)));
          final room = BgeTokens.standard.spaceMd;
          if (direction == TextDirection.ltr) {
            expect(row.left, box.left);
            expect(row.right, box.right - room);
          } else {
            expect(row.left, box.left + room);
            expect(row.right, box.right);
          }
        });
      }

      testWidgets("takes the caller's controller", (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _box(controller: controller), boxAfter: 2)),
        );
        await tester.pumpAndSettle();

        expect(controller.position, same(_inner(tester)));
        final top = tester.getTopLeft(find.byKey(_expansionKey(0))).dy;
        controller.jumpTo(60);
        await tester.pump();
        expect(tester.getTopLeft(find.byKey(_expansionKey(0))).dy, top - 60);

        // Without one it keeps its own, and takes the caller's back.
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();
        expect(controller.hasClients, isFalse);
        expect(_inner(tester).maxScrollExtent, greaterThan(0));
        await tester.pumpWidget(
          _app(_page(box: _box(controller: controller), boxAfter: 2)),
        );
        await tester.pumpAndSettle();
        expect(controller.position, same(_inner(tester)));
        expect(tester.takeException(), isNull);
      });

      testWidgets("a scroll view inside a row is told apart from the box's "
          'own', (tester) async {
        final depths = <Axis, Set<int>>{};
        final strip = ScrollController();
        addTearDown(strip.dispose);
        useViewSize(tester, _tall);
        await tester.pumpWidget(
          _app(
            _page(
              box: NotificationListener<ScrollUpdateNotification>(
                onNotification: (notification) {
                  depths
                      .putIfAbsent(notification.metrics.axis, () => {})
                      .add(notification.depth);
                  return false;
                },
                child: _box(
                  rows: [
                    SizedBox(
                      height: 60,
                      child: SingleChildScrollView(
                        controller: strip,
                        scrollDirection: Axis.horizontal,
                        child: const SizedBox(width: 2000, height: 60),
                      ),
                    ),
                    ..._sized([60, 60, 60, 60, 60]),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        strip.jumpTo(100);
        _inner(tester).jumpTo(40);
        await tester.pumpAndSettle();

        // The box's bar follows scrolls at depth 0 alone.
        expect(depths, {
          Axis.horizontal: {1},
          Axis.vertical: {0},
        });
        expect(tester.takeException(), isNull);
      });

      for (final ownController in [true, false]) {
        testWidgets('starts at its top on a page that keeps its own offset in '
            'page storage, and leaves none there — '
            '${ownController ? 'its own' : "a caller's"} controller', (
          tester,
        ) async {
          final storage = PageStorageBucket();
          final page = ScrollController();
          addTearDown(page.dispose);
          // As a caller makes one, keeping its offset.
          final rows = ScrollController();
          addTearDown(rows.dispose);
          useViewSize(tester, _phone);
          // A scroll view under a storage key, as a tab's is, saves its
          // offset under that key, and so would any other with no key of its
          // own.
          Widget app({required bool shown, bool unfolded = true}) => _app(
            PageStorage(
              bucket: storage,
              child: shown
                  ? KeyedSubtree(
                      key: const PageStorageKey<String>('tab'),
                      child: _page(
                        box: unfolded
                            ? _box(controller: ownController ? null : rows)
                            : null,
                        boxAfter: 12,
                        controller: page,
                      ),
                    )
                  : const SizedBox(),
            ),
          );
          await tester.pumpWidget(app(shown: true, unfolded: false));
          await tester.pumpAndSettle();
          page.jumpTo(700);
          await tester.pumpAndSettle();

          await tester.pumpWidget(app(shown: true));
          await tester.pumpAndSettle();

          expect(_theBox, findsOneWidget);
          expect(_inner(tester).pixels, 0);
          expect(page.offset, 700);

          // Nor does the box leave an offset of its own where the page keeps
          // its one: the tab left and come back to opens where it was.
          _inner(tester).jumpTo(120);
          await tester.pumpAndSettle();
          await tester.pumpWidget(app(shown: false));
          await tester.pumpWidget(app(shown: true));
          await tester.pumpAndSettle();

          expect(page.offset, 700);
          expect(_inner(tester).pixels, 0);
        });
      }

      testWidgets('the rows keep their offset as the box is built again', (
        tester,
      ) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();
        final rows = _inner(tester)..jumpTo(60);
        await tester.pumpAndSettle();

        // New widgets, the same box.
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();

        expect(_inner(tester), same(rows));
        expect(rows.pixels, 60);
      });

      testWidgets('a scroll view inside a row keeps the bar its platform '
          'gives it', (tester) async {
        const rowKey = Key('scrolling row');
        useViewSize(tester, _tall);
        await tester.pumpWidget(
          _app(
            _page(
              box: _box(
                rows: [
                  const SizedBox(
                    key: rowKey,
                    height: 60,
                    child: SingleChildScrollView(
                      child: SizedBox(height: 200),
                    ),
                  ),
                  ..._sized([60, 60, 60, 60, 60]),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The box turns off only its own: a desktop gives the row's one.
        expect(
          find.descendant(
            of: find.byKey(rowKey),
            matching: find.byType(Scrollbar),
          ),
          findsOneWidget,
        );
      }, variant: TargetPlatformVariant.desktop());

      testWidgets("a pull inside the box doesn't refresh the page", (
        tester,
      ) async {
        var refreshes = 0;
        useViewSize(tester, const Size(400, 800));
        await tester.pumpWidget(
          _app(_page(box: _box(), onRefresh: () async => refreshes++)),
        );
        await tester.pumpAndSettle();

        await tester.drag(_theBox, const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(refreshes, 0);

        // The same pull beside the box does.
        await tester.drag(find.byKey(_gameKey(0)), const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(refreshes, 1);
      });

      testWidgets('a mouse drags the thumb under the selection region, and '
          'selects nothing', (tester) async {
        final copies = captureClipboardCopies();
        await tester.pumpWidget(
          hostUnderSelectionRegion(
            tester,
            _page(box: _box(), boxAfter: 2),
            size: const Size(800, 600),
          ),
        );
        await tester.pumpAndSettle();
        final box = tester.getRect(_theBox);

        final onThumb = Offset(
          box.right - BgeTokens.standard.spaceSm,
          box.top + BgeTokens.standard.spaceLg,
        );
        await mouseDrag(tester, onThumb, onThumb + const Offset(0, 80));
        await tester.pumpAndSettle();

        expect(_inner(tester).pixels, greaterThan(0));
        await sendCopyShortcut(tester);
        expect(copies, isEmpty);
      });
    });

    group('keyboard', () {
      testWidgets('Tab scrolls a hidden inner row into view', (tester) async {
        useViewSize(tester, _phone);
        // Low enough that the box itself runs below the fold.
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 4)));
        await tester.pumpAndSettle();
        expect(tester.getRect(_theBox).bottom, greaterThan(_phone.height));
        // Hidden twice over: past the box's end, and below the page's.
        expect(
          _within(
            tester.getRect(find.byKey(_expansionKey(7))),
            _rowsRect(tester),
          ),
          isFalse,
        );

        for (var game = 0; game <= 4; game++) {
          await _tab(tester);
        }
        expect(_focusedTitle(tester), 'Game 4');

        for (var id = 0; id < 8; id++) {
          await _tab(tester);

          expect(_focusedTitle(tester), 'Expansion $id');
          final row = _focusOf(tester, 'Expansion $id').rect;
          expect(
            _within(row, _rowsRect(tester)),
            isTrue,
            reason: 'Expansion $id is not whole in the box',
          );
          expect(
            _within(row, _pageRect(tester)),
            isTrue,
            reason: 'Expansion $id is not whole on the page',
          );
        }

        // The box moved its rows, and the page moved the box.
        expect(_inner(tester).pixels, greaterThan(0));
        expect(_outer(tester).pixels, greaterThan(0));
      });

      testWidgets('Tab goes through the rows in order, between the row above '
          'the box and the row below it, and Shift+Tab goes back', (
        tester,
      ) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 1)));
        await tester.pumpAndSettle();
        const order = [
          'Game 0',
          'Game 1',
          'Expansion 0',
          'Expansion 1',
          'Expansion 2',
          'Expansion 3',
          'Expansion 4',
          'Expansion 5',
          'Expansion 6',
          'Expansion 7',
          'Game 2',
          'Game 3',
        ];

        final forward = <String?>[];
        for (var i = 0; i < order.length; i++) {
          await _tab(tester);
          forward.add(_focusedTitle(tester));
        }
        expect(forward, order);

        final back = <String?>[];
        for (var i = 0; i < order.length - 1; i++) {
          await _tab(tester, back: true);
          back.add(_focusedTitle(tester));
        }
        expect(back, order.reversed.skip(1));
      });

      testWidgets('a row taller than the box is shown from its top', (
        tester,
      ) async {
        useViewSize(tester, _narrowPortrait);
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(_expansionKey(1))).height,
          greaterThan(tester.getSize(_theBox).height),
        );

        // Game 0, Expansion 0, Expansion 1.
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);

        expect(_focusedTitle(tester), 'Expansion 1');
        final box = tester.getRect(_theBox);
        expect(
          tester.getRect(find.byKey(_expansionKey(1))).top,
          moreOrLessEquals(box.top),
        );
        expect(_within(box, _pageRect(tester)), isTrue);

        // And coming back up to one.
        await _tab(tester);
        await _tab(tester, back: true);
        expect(_focusedTitle(tester), 'Expansion 1');
        expect(
          tester.getRect(find.byKey(_expansionKey(1))).top,
          moreOrLessEquals(tester.getRect(_theBox).top),
        );
      });
    });

    group('focus that arrives in a row from code', () {
      testWidgets('with the keyboard in use, a hidden row is shown in the '
          'box, and the page shows the box', (tester) async {
        useViewSize(tester, _phone);
        // Low enough that the box itself runs below the fold.
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 4)));
        await tester.pumpAndSettle();
        expect(tester.getRect(_theBox).bottom, greaterThan(_phone.height));
        final node = _focusOf(tester, 'Expansion 6');
        expect(_within(node.rect, _rowsRect(tester)), isFalse);
        // A key press, so focus is the keyboard's and is drawn.
        await _tab(tester);
        expect(_focusedTitle(tester), 'Game 0');

        // As a focus hand-off does: no traversal, and nothing asked to show.
        // The focus lands once this frame is over, and the page lays its
        // rows out at its new offset in the next.
        node.requestFocus();
        await tester.pump();
        await tester.pump();

        expect(node.hasPrimaryFocus, isTrue);
        expect(_within(node.rect, _rowsRect(tester)), isTrue);
        expect(_within(node.rect, _pageRect(tester)), isTrue);
        expect(_inner(tester).pixels, greaterThan(0));
        expect(_outer(tester).pixels, greaterThan(0));
      });

      testWidgets('a hidden row taller than the box is shown from its top', (
        tester,
      ) async {
        useViewSize(tester, _narrowPortrait);
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));
        await tester.pumpAndSettle();
        await _tab(tester);
        final node = _focusOf(tester, 'Expansion 2')..requestFocus();
        await tester.pump();
        await tester.pump();

        expect(node.hasPrimaryFocus, isTrue);
        expect(
          tester.getRect(find.byKey(_expansionKey(2))).top,
          moreOrLessEquals(_rowsRect(tester).top),
        );
      });

      testWidgets('a row already in view moves nothing', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        final node = _focusOf(tester, 'Expansion 1');
        expect(_within(node.rect, _rowsRect(tester)), isTrue);

        node.requestFocus();
        await tester.pump();
        await tester.pump();

        expect(node.hasPrimaryFocus, isTrue);
        expect(_inner(tester).pixels, 0);
        expect(_outer(tester).pixels, 0);
      });

      testWidgets("a row outside the box is none of the box's to show", (
        tester,
      ) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 1)));
        await tester.pumpAndSettle();
        _inner(tester).jumpTo(100);
        await tester.pumpAndSettle();
        await _tab(tester);
        // A row of the page's own, cut short by the fold.
        final node = _focusOf(tester, 'Game 3');
        expect(_within(node.rect, _pageRect(tester)), isFalse);

        node.requestFocus();
        await tester.pump();
        await tester.pump();

        // The page's rows are the page's to show, or not.
        expect(node.hasPrimaryFocus, isTrue);
        expect(_inner(tester).pixels, 100);
        expect(_outer(tester).pixels, 0);
      });

      testWidgets('a row taller than the box that covers it, being read '
          'part-way, stays where it is', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _box(rows: _tallRows()), boxAfter: 1)),
        );
        await tester.pumpAndSettle();
        // Game 0, Game 1, then Expansion 0, and on down inside it.
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        final rows = _inner(tester).pixels;
        final page = _outer(tester).pixels;
        expect(rows, greaterThan(0));
        final row = tester.getRect(find.byKey(_expansionKey(0)));
        expect(row.top, lessThan(_rowsRect(tester).top));
        expect(row.bottom, greaterThan(_rowsRect(tester).bottom));

        // Away, and handed back.
        _focusOf(tester, 'Game 0').requestFocus();
        await tester.pump();
        _focusOf(tester, 'Expansion 0').requestFocus();
        await tester.pump();
        await tester.pump();

        expect(_focusedTitle(tester), 'Expansion 0');
        expect(_inner(tester).pixels, rows);
        expect(_outer(tester).pixels, page);
      });

      testWidgets('one that shows only its end comes down to fill the box, '
          'and not back to its top', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _box(rows: _tallRows()), boxAfter: 1)),
        );
        await tester.pumpAndSettle();
        await _tab(tester);
        // A strip of the first row at the box's top, the second under it.
        _inner(tester).jumpTo(_tallRow - 50);
        await tester.pumpAndSettle();
        final view = _rowsRect(tester);
        expect(
          tester.getRect(find.byKey(_expansionKey(0))).bottom,
          view.top + 50,
        );

        _focusOf(tester, 'Expansion 0').requestFocus();
        await tester.pump();
        await tester.pump();

        // Its end at the box's end: all of the box is the focused row.
        expect(_focusedTitle(tester), 'Expansion 0');
        expect(_inner(tester).pixels, _tallRow - view.height);
        final row = tester.getRect(find.byKey(_expansionKey(0)));
        expect(row.top, lessThan(_rowsRect(tester).top));
        expect(row.bottom, _rowsRect(tester).bottom);
      });

      testWidgets('focus given back as the window comes back moves nothing', (
        tester,
      ) async {
        useViewSize(tester, _narrowPortrait);
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));
        await tester.pumpAndSettle();
        // Game 0, then Expansion 0, and on down inside it.
        await _tab(tester);
        await _tab(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        // Then the page is moved on, the box nearly out of it.
        _outer(tester).jumpTo(_outer(tester).pixels + 200);
        await tester.pumpAndSettle();
        final rows = _inner(tester).pixels;
        final page = _outer(tester).pixels;
        expect(rows, greaterThan(0));
        final node = _focusOf(tester, 'Expansion 0');
        expect(node.hasPrimaryFocus, isTrue);

        // The window, or the browser's tab, loses the focus and gets it
        // back. The framework parks the focus on its root meanwhile, and
        // asks for it again for the node that had it.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus,
          same(FocusManager.instance.rootScope),
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump();

        expect(node.hasPrimaryFocus, isTrue);
        expect(_inner(tester).pixels, rows);
        expect(_outer(tester).pixels, page);
        // The framework parks the focus so on these platforms and the web.
      }, variant: TargetPlatformVariant.desktop());

      testWidgets("while the focus is a pointer's, and so undrawn, a hidden "
          'row is left where it is', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 1)));
        await tester.pumpAndSettle();
        // A touch, on the app bar: nothing there takes it.
        await tester.tapAt(const Offset(200, 20));
        await tester.pump();
        final node = _focusOf(tester, 'Expansion 6')..requestFocus();
        await tester.pump();
        await tester.pump();

        expect(node.hasPrimaryFocus, isTrue);
        expect(_inner(tester).pixels, 0);
        expect(_outer(tester).pixels, 0);
      });
    });

    group('focus that a press gives a row', () {
      Future<void> pressTheHalfRow(
        WidgetTester tester,
        PointerDeviceKind kind,
      ) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(
            _page(
              box: _box(rows: _expansions(focusOnTap: true)),
              boxAfter: 1,
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The row the box cuts short at rest.
        final row = tester.getRect(find.byKey(_expansionKey(3)));
        final view = _rowsRect(tester);
        expect(row.top, lessThan(view.bottom));
        expect(row.bottom, greaterThan(view.bottom));

        await tester.tapAt(
          Offset(row.center.dx, (row.top + view.bottom) / 2),
          kind: kind,
        );
        await tester.pump();
        await tester.pump();

        expect(_focusedTitle(tester), 'Expansion 3');
      }

      testWidgets('a tap on the half row at the end of the box scrolls '
          'nothing under the finger', (tester) async {
        await pressTheHalfRow(tester, PointerDeviceKind.touch);

        expect(_inner(tester).pixels, 0);
        expect(_outer(tester).pixels, 0);
      });

      testWidgets('nor does a mouse click, under the pointer', (tester) async {
        await pressTheHalfRow(tester, PointerDeviceKind.mouse);

        expect(_inner(tester).pixels, 0);
        expect(_outer(tester).pixels, 0);
      }, variant: TargetPlatformVariant.desktop());
    });

    group('keyboard scrolling', () {
      testWidgets('Page Down with focus on a row moves the rows, not the '
          'page, so the rest of a row taller than the box can be read', (
        tester,
      ) async {
        useViewSize(tester, _narrowPortrait);
        await tester.pumpWidget(_app(_page(box: _box()), textScale: 2));
        await tester.pumpAndSettle();
        // Game 0, then Expansion 0, which is taller than the box.
        await _tab(tester);
        await _tab(tester);
        expect(_focusedTitle(tester), 'Expansion 0');
        final row = tester.getRect(find.byKey(_expansionKey(0)));
        expect(row.bottom, greaterThan(_rowsRect(tester).bottom));

        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();

        expect(_inner(tester).pixels, greaterThan(0));
        expect(_outer(tester).pixels, 0);
        expect(_focusedTitle(tester), 'Expansion 0');
      });
    });

    group('a box that takes focus itself, for rows that take none', () {
      testWidgets('is one Tab stop, between the row above it and the row '
          'below', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();

        await _tab(tester);
        expect(_focusedTitle(tester), 'Game 0');
        await _tab(tester);
        expect(_focusedTitle(tester), 'Game 1');
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        expect(_focusedTitle(tester), isNull);
        await _tab(tester);
        expect(_focusedTitle(tester), 'Game 2');

        await _tab(tester, back: true);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        await _tab(tester, back: true);
        expect(_focusedTitle(tester), 'Game 1');
      });

      testWidgets('Tab brings it into view on the page, and leaves its rows '
          'where they are', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 4)));
        await tester.pumpAndSettle();
        expect(tester.getRect(_theBox).bottom, greaterThan(_phone.height));

        for (var game = 0; game <= 4; game++) {
          await _tab(tester);
        }
        await _tab(tester);

        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        expect(_within(_rowsRect(tester), _pageRect(tester)), isTrue);
        expect(_outer(tester).pixels, greaterThan(0));
        expect(_inner(tester).pixels, 0);
      });

      testWidgets('without the flag, rows that take no focus leave the box '
          'no stop', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _inertBox(focusable: false), boxAfter: 1)),
        );
        await tester.pumpAndSettle();

        final stops = <String?>[];
        for (var i = 0; i < 3; i++) {
          await _tab(tester);
          stops.add(_focusedTitle(tester));
        }
        expect(stops, ['Game 0', 'Game 1', 'Game 2']);
      });

      testWidgets('with no more than inlineLimit rows it has nothing to '
          'scroll, and is no stop', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _inertBox(count: 4), boxAfter: 1)),
        );
        await tester.pumpAndSettle();

        final stops = <String?>[];
        for (var i = 0; i < 3; i++) {
          await _tab(tester);
          stops.add(_focusedTitle(tester));
        }
        expect(stops, ['Game 0', 'Game 1', 'Game 2']);
      });

      testWidgets('is named by its label, and says when it has focus', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();

        var group = _groupNode(tester).getSemanticsData();
        expect(group.label, _label);
        // Able to take focus, and without it.
        expect(group.flagsCollection.isFocused, Tristate.isFalse);
        expect(group.hasAction(SemanticsAction.focus), isTrue);

        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        group = _groupNode(tester).getSemanticsData();
        expect(group.label, _label);
        expect(group.flagsCollection.isFocused, Tristate.isTrue);
        // The rows still count under it.
        expect(_innerListNode(tester).scrollChildCount, 8);
        // And the stop is that one node: none under it takes focus beside.
        for (final child in _childrenOf(_groupNode(tester))) {
          expect(
            _firstNode(
              child,
              (node) => node.flagsCollection.isFocused != Tristate.none,
            ),
            isNull,
          );
        }
        semantics.dispose();
      });

      testWidgets('a screen reader can give it the focus', (tester) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();

        final group = _groupNode(tester);
        group.owner!.performAction(group.id, SemanticsAction.focus);
        await tester.pump();

        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        semantics.dispose();
      });

      testWidgets('without the flag its node takes no focus', (tester) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _inertBox(focusable: false), boxAfter: 1)),
        );
        await tester.pumpAndSettle();

        final group = _groupNode(tester).getSemanticsData();
        expect(group.flagsCollection.isFocused, Tristate.none);
        expect(group.hasAction(SemanticsAction.focus), isFalse);
        semantics.dispose();
      });

      testWidgets('the arrows move its rows a step, Page Up and Page Down a '
          'view less a step, and Home and End to the ends', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        final inner = _inner(tester);
        final page = _outer(tester).pixels;
        final step = BgeTokens.standard.spaceXxl;
        final view = inner.viewportDimension;

        // One frame each: the rows jump, so there is no motion to reduce.
        Future<void> press(LogicalKeyboardKey key) async {
          await tester.sendKeyEvent(key);
          await tester.pump();
        }

        await press(LogicalKeyboardKey.arrowDown);
        expect(inner.pixels, step);
        await press(LogicalKeyboardKey.arrowDown);
        expect(inner.pixels, 2 * step);
        await press(LogicalKeyboardKey.arrowUp);
        expect(inner.pixels, step);
        await press(LogicalKeyboardKey.arrowUp);
        expect(inner.pixels, 0);

        await press(LogicalKeyboardKey.pageDown);
        expect(inner.pixels, view - step);
        await press(LogicalKeyboardKey.pageUp);
        expect(inner.pixels, 0);

        await press(LogicalKeyboardKey.end);
        expect(inner.pixels, inner.maxScrollExtent);
        await press(LogicalKeyboardKey.home);
        expect(inner.pixels, 0);

        // A held key goes on.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(inner.pixels, 3 * step);

        // The box kept the focus, and the page never moved.
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        expect(_outer(tester).pixels, page);
      });

      testWidgets('a held arrow stops at the end of the rows, and a new press '
          "there is the page's", (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        final inner = _inner(tester);
        final page = _outer(tester).pixels;

        // Held from the top through the end: the repeats there go nowhere,
        // or the focus would run down the page after the rows.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        for (var i = 0; i < 30; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(inner.pixels, inner.maxScrollExtent);
        expect(_outer(tester).pixels, page);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        // A new press, with nothing left to show, scrolls the page as it
        // would from any other stop.
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expect(inner.pixels, inner.maxScrollExtent);
        expect(_outer(tester).pixels, greaterThan(page));
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        // So is a new Arrow Down, unlike the held one's repeats: the focus
        // moves on down the page, and the rows stay at their end.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(inner.pixels, inner.maxScrollExtent);
        expect(_boxFocus(tester).hasFocus, isFalse);
      });

      testWidgets('a held Home or End stops at its end of the rows: the jump '
          'is made, and the page stays', (tester) async {
        useViewSize(tester, _phone);
        // Home and End as a host could have them, scrolling the page, so a
        // repeat let through would show.
        await tester.pumpWidget(
          _app(
            _page(box: _inertBox(), boxAfter: 1),
            shortcuts: {
              ...WidgetsApp.defaultShortcuts,
              const SingleActivator(LogicalKeyboardKey.end): const ScrollIntent(
                direction: AxisDirection.down,
                type: ScrollIncrementType.page,
              ),
              const SingleActivator(
                LogicalKeyboardKey.home,
              ): const ScrollIntent(
                direction: AxisDirection.up,
                type: ScrollIncrementType.page,
              ),
            },
          ),
        );
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        final inner = _inner(tester);
        final page = _outer(tester).pixels;

        await tester.sendKeyDownEvent(LogicalKeyboardKey.end);
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.end);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.end);
        await tester.pumpAndSettle();
        expect(inner.pixels, inner.maxScrollExtent);
        expect(_outer(tester).pixels, page);

        // The page a little down, so a repeat let through to Home's page
        // scroll would have room to show.
        final outer = _outer(tester)..jumpTo(page + 20);
        await tester.pump();
        expect(outer.pixels, greaterThan(outer.minScrollExtent));
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        final down = outer.pixels;

        await tester.sendKeyDownEvent(LogicalKeyboardKey.home);
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.home);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(inner.pixels, 0);
        expect(outer.pixels, down);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets('a held Page Down carries on down the page from the end of '
          'the rows, as it would on a web page', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        final inner = _inner(tester);
        final page = _outer(tester).pixels;

        await tester.sendKeyDownEvent(LogicalKeyboardKey.pageDown);
        expect(inner.pixels, greaterThan(0));
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageDown);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();

        expect(inner.pixels, inner.maxScrollExtent);
        expect(_outer(tester).pixels, greaterThan(page));
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        // And back up: held Page Up takes the rows to their top, then the
        // page.
        final scrolled = _outer(tester).pixels;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.pageUp);
        for (var i = 0; i < 6; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.pageUp);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.pageUp);
        await tester.pumpAndSettle();
        expect(inner.pixels, 0);
        expect(_outer(tester).pixels, lessThan(scrolled));
      });

      testWidgets('Space and Shift+Space move the rows as Page Down and Page '
          "Up do, and at the rows' end Space is the page's", (tester) async {
        useViewSize(tester, _phone);
        // Space as the web has it: a page down where nothing takes it.
        await tester.pumpWidget(
          _app(
            _page(box: _inertBox(), boxAfter: 1),
            shortcuts: {
              ...WidgetsApp.defaultShortcuts,
              const SingleActivator(
                LogicalKeyboardKey.space,
              ): const ScrollIntent(
                direction: AxisDirection.down,
                type: ScrollIncrementType.page,
              ),
            },
          ),
        );
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        final inner = _inner(tester);
        final page = _outer(tester).pixels;
        final step = BgeTokens.standard.spaceXxl;
        final view = inner.viewportDimension;

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(inner.pixels, view - step);
        expect(_outer(tester).pixels, page);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
        await tester.pump();
        expect(inner.pixels, 0);
        expect(_outer(tester).pixels, page);

        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(inner.pixels, inner.maxScrollExtent);
        expect(_outer(tester).pixels, greaterThan(page));
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
      });

      testWidgets('a chord is left alone', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pumpAndSettle();

        expect(_inner(tester).pixels, 0);
      });

      testWidgets('the ring shows on keyboard focus, and not after a mouse '
          'press', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        expect(_ringShown(tester), isFalse);

        await _tab(tester);
        await _tab(tester);
        expect(_ringShown(tester), isFalse);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        expect(_ringShown(tester), isTrue);

        // On the app bar: no control takes the press, or the focus.
        await tester.tapAt(
          const Offset(200, 20),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        expect(_ringShown(tester), isFalse);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(_ringShown(tester), isTrue, reason: 'a key press');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        // And it goes with the focus.
        await _tab(tester);
        expect(_focusedTitle(tester), 'Game 2');
        expect(_ringShown(tester), isFalse);
      }, variant: TargetPlatformVariant.desktop());

      testWidgets('when the flag goes while the box has focus, the first row '
          'that takes focus has it', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        // The rows can be opened now, so the caller drops the flag.
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 1)));
        await tester.pump();

        expect(_focusedTitle(tester), 'Expansion 0');
      });

      testWidgets('when the rows drop to inlineLimit while the box has '
          'focus, the first row that takes focus has it', (tester) async {
        useViewSize(tester, _phone);
        Widget app(int count) => _app(
          _page(
            box: _box(rows: _expansions(count: count), focusable: true),
            boxAfter: 1,
          ),
        );
        await tester.pumpWidget(app(5));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        await tester.pumpWidget(app(4));
        await tester.pump();

        expect(_focusedTitle(tester), 'Expansion 0');
      });

      testWidgets('with the rows scrolled, the first row in view has it, not '
          'the first of all', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        // Four steps down: the third row is cut short at the top.
        for (var i = 0; i < 4; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        final step = BgeTokens.standard.spaceXxl;
        expect(_inner(tester).pixels, 4 * step);
        final cut = tester.getRect(find.byKey(_expansionKey(2)));
        expect(cut.top, lessThan(_rowsRect(tester).top));
        expect(cut.bottom, greaterThan(_rowsRect(tester).top));

        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 1)));
        await tester.pump();
        await tester.pump();

        // That row, brought whole into view: less than a row's move.
        expect(_focusedTitle(tester), 'Expansion 2');
        expect(
          tester.getRect(find.byKey(_expansionKey(2))).top,
          _rowsRect(tester).top,
        );
        expect(_inner(tester).pixels, greaterThan(3 * step));
      });

      testWidgets('with a row taller than the box covering it, that row has '
          'it, and the rows stay where they are', (tester) async {
        useViewSize(tester, _phone);
        Widget app({required bool stop}) => _app(
          _page(
            box: _box(
              rows: _tallRows(inert: stop),
              focusable: stop,
            ),
            boxAfter: 1,
          ),
        );
        await tester.pumpWidget(app(stop: true));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        for (var i = 0; i < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        final rows = _inner(tester).pixels;
        final page = _outer(tester).pixels;
        expect(rows, 3 * BgeTokens.standard.spaceXxl);

        await tester.pumpWidget(app(stop: false));
        await tester.pump();
        await tester.pump();

        expect(_focusedTitle(tester), 'Expansion 0');
        expect(_inner(tester).pixels, rows);
        expect(_outer(tester).pixels, page);
      });

      testWidgets('with only the end of a tall row showing at the top, that '
          'row has it and comes down to fill the box', (tester) async {
        useViewSize(tester, _phone);
        Widget app({required bool stop}) => _app(
          _page(
            box: _box(
              rows: _tallRows(inert: stop),
              focusable: stop,
            ),
            boxAfter: 1,
          ),
        );
        await tester.pumpWidget(app(stop: true));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        // Fourteen steps down: a strip of the first row is left at the top.
        for (var i = 0; i < 14; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        final step = BgeTokens.standard.spaceXxl;
        expect(_inner(tester).pixels, 14 * step);
        final view = _rowsRect(tester);
        expect(
          tester.getRect(find.byKey(_expansionKey(0))).bottom,
          view.top + _tallRow - 14 * step,
        );

        await tester.pumpWidget(app(stop: false));
        await tester.pump();
        await tester.pump();

        // Not left as a strip under its ring, and not back at its top.
        expect(_focusedTitle(tester), 'Expansion 0');
        expect(_inner(tester).pixels, _tallRow - view.height);
        expect(
          tester.getRect(find.byKey(_expansionKey(0))).bottom,
          _rowsRect(tester).bottom,
        );
      });

      testWidgets('the first row is the one at the top, whenever it '
          'arrived', (tester) async {
        useViewSize(tester, _phone);
        Widget app(List<int> ids, {required bool stop}) => _app(
          _page(
            box: _box(
              rows: _expansions(ids: ids),
              focusable: stop,
            ),
            boxAfter: 1,
          ),
        );
        await tester.pumpWidget(app([1, 2, 3, 4, 5], stop: true));
        await tester.pumpAndSettle();
        // A row arrives above the rest, as a later page's would.
        await tester.pumpWidget(app([0, 1, 2, 3, 4, 5], stop: true));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        await tester.pumpWidget(app([0, 1, 2, 3, 4, 5], stop: false));
        await tester.pump();

        expect(_focusedTitle(tester), 'Expansion 0');
      });

      for (final direction in TextDirection.values) {
        testWidgets('of two stops as high in the first row, the one at the '
            'start has it — ${direction.name}', (tester) async {
          // Built end first, so the order they were built in is no guide.
          final endFirst = direction == TextDirection.ltr
              ? TextDirection.rtl
              : TextDirection.ltr;
          List<Widget> rows() => [
            for (var i = 0; i < 6; i++)
              Row(
                key: _expansionKey(i),
                textDirection: endFirst,
                children: [
                  TextButton(onPressed: () {}, child: Text('End $i')),
                  TextButton(onPressed: () {}, child: Text('Start $i')),
                ],
              ),
          ];
          useViewSize(tester, _phone);
          Widget app({required bool stop}) => _app(
            _page(
              box: _box(rows: rows(), focusable: stop),
              boxAfter: 1,
            ),
            direction: direction,
          );
          await tester.pumpWidget(app(stop: true));
          await tester.pumpAndSettle();
          await _tab(tester);
          await _tab(tester);
          await _tab(tester);
          expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

          await tester.pumpWidget(app(stop: false));
          await tester.pump();

          expect(_focusOf(tester, 'Start 0').hasPrimaryFocus, isTrue);
        });

        testWidgets('of two stops in the first row, the one at the start '
            'has it though the other stands higher — ${direction.name}', (
          tester,
        ) async {
          final endFirst = direction == TextDirection.ltr
              ? TextDirection.rtl
              : TextDirection.ltr;
          // The end one is the taller, so its top is the higher.
          List<Widget> rows() => [
            for (var i = 0; i < 6; i++)
              Row(
                key: _expansionKey(i),
                textDirection: endFirst,
                children: [
                  SizedBox(
                    height: 72,
                    child: TextButton(
                      onPressed: () {},
                      child: Text('End $i'),
                    ),
                  ),
                  TextButton(onPressed: () {}, child: Text('Start $i')),
                ],
              ),
          ];
          useViewSize(tester, _phone);
          Widget app({required bool stop}) => _app(
            _page(
              box: _box(rows: rows(), focusable: stop),
              boxAfter: 1,
            ),
            direction: direction,
          );
          await tester.pumpWidget(app(stop: true));
          await tester.pumpAndSettle();
          expect(
            _focusOf(tester, 'End 0').rect.top,
            lessThan(_focusOf(tester, 'Start 0').rect.top),
          );
          await _tab(tester);
          await _tab(tester);
          await _tab(tester);
          expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

          await tester.pumpWidget(app(stop: false));
          await tester.pump();

          expect(_focusOf(tester, 'Start 0').hasPrimaryFocus, isTrue);
        });

        testWidgets('of two stops in a part of the first row set the other '
            'way, the one that part reads first has it, as Tab would — '
            '${direction.name}', (tester) async {
          final other = direction == TextDirection.ltr
              ? TextDirection.rtl
              : TextDirection.ltr;
          // Read in [other], First stands at the end of the page's line.
          List<Widget> rows() => [
            for (var i = 0; i < 6; i++)
              Directionality(
                key: _expansionKey(i),
                textDirection: other,
                child: Row(
                  children: [
                    TextButton(onPressed: () {}, child: Text('First $i')),
                    TextButton(onPressed: () {}, child: Text('Second $i')),
                  ],
                ),
              ),
          ];
          useViewSize(tester, _phone);
          Widget app({required bool stop}) => _app(
            _page(
              box: _box(rows: rows(), focusable: stop),
              boxAfter: 1,
            ),
            direction: direction,
          );
          await tester.pumpWidget(app(stop: true));
          await tester.pumpAndSettle();
          final first = _focusOf(tester, 'First 0').rect;
          final second = _focusOf(tester, 'Second 0').rect;
          expect(
            direction == TextDirection.ltr
                ? first.left > second.left
                : first.left < second.left,
            isTrue,
            reason: "First stands at the end of the page's line",
          );
          await _tab(tester);
          await _tab(tester);
          await _tab(tester);
          expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

          await tester.pumpWidget(app(stop: false));
          await tester.pump();

          expect(_focusOf(tester, 'First 0').hasPrimaryFocus, isTrue);
        });
      }

      testWidgets('of two stops one under the other in the first row, the '
          'upper has it though the lower starts nearer the start', (
        tester,
      ) async {
        List<Widget> rows() => [
          for (var i = 0; i < 6; i++)
            Column(
              key: _expansionKey(i),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: BgeTokens.spaceLgValue,
                  ),
                  child: TextButton(onPressed: () {}, child: Text('Upper $i')),
                ),
                TextButton(onPressed: () {}, child: Text('Lower $i')),
              ],
            ),
        ];
        useViewSize(tester, _phone);
        Widget app({required bool stop}) => _app(
          _page(
            box: _box(rows: rows(), focusable: stop),
            boxAfter: 1,
          ),
        );
        await tester.pumpWidget(app(stop: true));
        await tester.pumpAndSettle();
        expect(
          _focusOf(tester, 'Lower 0').rect.left,
          lessThan(_focusOf(tester, 'Upper 0').rect.left),
        );
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        await tester.pumpWidget(app(stop: false));
        await tester.pump();

        expect(_focusOf(tester, 'Upper 0').hasPrimaryFocus, isTrue);
      });

      testWidgets('with no row to take it, the focus is left where the '
          "framework puts it, for the caller's hand-off", (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _inertBox(count: 5), boxAfter: 1)),
        );
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);

        await tester.pumpWidget(
          _app(_page(box: _inertBox(count: 4), boxAfter: 1)),
        );
        await tester.pump();

        // Here that is the stop focus came from. The box has no say in it.
        expect(_boxFocus(tester).hasPrimaryFocus, isFalse);
        expect(
          _inTheBox(tester, FocusManager.instance.primaryFocus),
          isFalse,
        );
      });

      testWidgets('a box that stops being a stop without the focus moves '
          'none', (tester) async {
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _inertBox(), boxAfter: 1)));
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        expect(_focusedTitle(tester), 'Game 1');

        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 1)));
        await tester.pump();

        expect(_focusedTitle(tester), 'Game 1');
      });

      testWidgets("the ring is the box's own: focus on a row inside it draws "
          'none, and leaves the arrows to the framework', (tester) async {
        useViewSize(tester, _phone);
        // A caller that sets the flag over rows that do take focus.
        await tester.pumpWidget(
          _app(_page(box: _box(focusable: true), boxAfter: 1)),
        );
        await tester.pumpAndSettle();
        await _tab(tester);
        await _tab(tester);
        await _tab(tester);
        expect(_boxFocus(tester).hasPrimaryFocus, isTrue);
        expect(_ringShown(tester), isTrue);

        await _tab(tester);
        expect(_focusedTitle(tester), 'Expansion 0');
        expect(_ringShown(tester), isFalse);

        // Down is the framework's move to the next row, not the box's step.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(_focusedTitle(tester), 'Expansion 1');
        expect(_inner(tester).pixels, 0);
      });
    });

    group('semantics', () {
      testWidgets('inner rows read n of m', (tester) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();

        // The box's own list: m, and where it is among them.
        var list = _innerListNode(tester);
        expect(list.scrollChildCount, 8);
        expect(list.getSemanticsData().scrollIndex, 0);
        expect(
          list.getSemanticsData().hasAction(SemanticsAction.scrollUp),
          isTrue,
        );
        expect(
          list.getSemanticsData().flagsCollection.hasImplicitScrolling,
          isTrue,
        );

        // Each row: n, with its words on the node inside it.
        final rows = _childrenOf(list);
        expect(
          [for (final row in rows) row.indexInParent],
          [
            0,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
          ],
        );
        for (final (index, row) in rows.indexed) {
          expect(
            _firstNode(
              row,
              (node) => node.label.startsWith('Expansion $index'),
            ),
            isNotNull,
          );
        }
        // Every row stays in the tree, hidden while out of view, so a screen
        // reader can move on to it.
        expect(
          [for (final row in rows) row.flagsCollection.isHidden],
          [false, false, false, false, true, true, true, true],
        );

        // Scrolled to its end, it says which row is first in view.
        _inner(tester).jumpTo(_inner(tester).maxScrollExtent);
        await tester.pumpAndSettle();
        list = _innerListNode(tester);
        expect(list.scrollChildCount, 8);
        expect(list.getSemanticsData().scrollIndex, 4);

        // The page keeps its own count, on its own node.
        final page = _firstNode(
          _semanticsRoot(tester),
          (node) => node.scrollChildCount != null,
        )!;
        expect(page.scrollChildCount, _pageCount);
        expect(page.id, isNot(list.id));
        // Among the page's items the box is one, in its place.
        final group = _groupNode(tester);
        expect(group.parent!.indexInParent, 3);
        semantics.dispose();
      });

      testWidgets('a group named by its label', (tester) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 2)));
        await tester.pumpAndSettle();

        final group = tester.getSemantics(_theBox);
        expect(group.label, _label);
        // Its own node, with the rows under it, not merged into its name.
        expect(
          _firstNode(group, (node) => node.scrollChildCount == 8),
          isNotNull,
        );
        semantics.dispose();
      });

      testWidgets("a screen reader's move to a hidden row shows it, in the "
          'box and then on the page', (tester) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(_app(_page(box: _box(), boxAfter: 4)));
        await tester.pumpAndSettle();
        final row = tester.getSemantics(find.text('Expansion 6'));
        expect(row.flagsCollection.isHidden, isTrue);

        row.owner!.performAction(row.id, SemanticsAction.showOnScreen);
        await tester.pumpAndSettle();

        expect(_inner(tester).pixels, greaterThan(0));
        expect(_outer(tester).pixels, greaterThan(0));
        final shown = _focusOf(tester, 'Expansion 6').rect;
        expect(_within(shown, _rowsRect(tester)), isTrue);
        expect(_within(shown, _pageRect(tester)), isTrue);
        semantics.dispose();
      });
    });

    group('a screen reader showing a row taller than the box', () {
      testWidgets('one that shows only its end comes down to fill the box', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _box(rows: _tallRows()), boxAfter: 1)),
        );
        await tester.pumpAndSettle();
        _inner(tester).jumpTo(_tallRow - 50);
        await tester.pumpAndSettle();
        final view = _rowsRect(tester);
        final row = tester.getSemantics(find.text('Expansion 0'));
        expect(row.flagsCollection.isHidden, isFalse);

        row.owner!.performAction(row.id, SemanticsAction.showOnScreen);
        await tester.pumpAndSettle();

        expect(_inner(tester).pixels, _tallRow - view.height);
        semantics.dispose();
      });

      testWidgets('one that covers the box stays where it is', (tester) async {
        final semantics = tester.ensureSemantics();
        useViewSize(tester, _phone);
        await tester.pumpWidget(
          _app(_page(box: _box(rows: _tallRows()), boxAfter: 1)),
        );
        await tester.pumpAndSettle();
        _inner(tester).jumpTo(200);
        // The page scrolled until the box's top is out of its view, so the
        // ask has to reach the page to show the box whole.
        final outer = _outer(tester);
        outer.jumpTo(
          outer.pixels + _rowsRect(tester).top - _pageRect(tester).top + 40,
        );
        await tester.pumpAndSettle();
        expect(_within(_rowsRect(tester), _pageRect(tester)), isFalse);
        final page = outer.pixels;
        final row = tester.getSemantics(find.text('Expansion 0'));

        row.owner!.performAction(row.id, SemanticsAction.showOnScreen);
        await tester.pumpAndSettle();

        expect(_inner(tester).pixels, 200);
        expect(outer.pixels, lessThan(page));
        expect(_within(_rowsRect(tester), _pageRect(tester)), isTrue);
        semantics.dispose();
      });
    });

    group('rows', () {
      testWidgets('a keyed row keeps its focus as rows above it leave and '
          'arrive', (tester) async {
        useViewSize(tester, const Size(400, 800));
        Widget app(List<int> ids) => _app(
          _page(
            box: _box(rows: _expansions(ids: ids)),
          ),
        );
        await tester.pumpWidget(app([0, 1, 2, 3, 4, 5]));
        await tester.pumpAndSettle();
        // Game 0, then Expansions 0, 1 and 2.
        for (var i = 0; i < 4; i++) {
          await _tab(tester);
        }
        expect(_focusedTitle(tester), 'Expansion 2');
        final node = _focusOf(tester, 'Expansion 2');

        await tester.pumpWidget(app([1, 2, 3, 4, 5, 6]));
        await tester.pumpAndSettle();
        expect(_focusOf(tester, 'Expansion 2'), same(node));
        expect(node.hasPrimaryFocus, isTrue);

        await tester.pumpWidget(app([7, 1, 2, 3, 4, 5, 6]));
        await tester.pumpAndSettle();
        expect(_focusOf(tester, 'Expansion 2'), same(node));
        expect(node.hasPrimaryFocus, isTrue);

        // A row's key still finds the row alone.
        expect(find.byKey(_expansionKey(2)), findsOneWidget);
      });

      testWidgets('a row may carry a global key', (tester) async {
        final key = GlobalKey();
        useViewSize(tester, _tall);
        await tester.pumpWidget(
          _app(
            _page(
              box: _box(
                rows: [
                  SizedBox(key: key, height: 40),
                  ..._sized([40, 40, 40, 40, 40]).skip(1),
                ],
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.byKey(key), findsOneWidget);
      });
    });
  });
}
