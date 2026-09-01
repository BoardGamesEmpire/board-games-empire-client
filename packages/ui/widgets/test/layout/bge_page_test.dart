import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Sets the actual render surface, then hosts [child].
///
/// `MediaQueryData.size` is **metadata, not layout constraints** — a widget
/// under `MediaQuery(size: Size(320, 480))` still lays out against the test
/// view's 800x600. Every "narrow window" case here previously set only that
/// field, so it ran at 800 wide and tested nothing about narrow windows. The
/// size has to go on `tester.view`.
///
/// The text scaler is different: an ancestor `MediaQuery` IS effective. The
/// framework's own `MediaQuery.fromView` is inserted by `View`, ABOVE the
/// widget under test — `WidgetsApp` inserts none of its own — so this wrapper
/// sits below it and wins. Verified, not assumed.
Widget _host(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
  double scale = 1,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  return MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
    child: MaterialApp(theme: BgeTheme.light(), home: child),
  );
}

/// The count a screen reader reads as "item 3 of 9", taken off the node that
/// actually scrolls.
///
/// Walked rather than fetched with `tester.getSemantics`, which resolves to the
/// nearest merged ancestor — that is not the viewport's node, so it reports
/// null whether or not the count is wired, and an assertion built on it passes
/// for the broken case. `SettingsScreen`'s test carries the same walk; this is
/// the primitive's own copy, so the guarantee is tested where it is made.
int? _countOnScrollingNode(WidgetTester tester) {
  SemanticsNode? root;
  tester.binding.rootPipelineOwner.visitChildren((owner) {
    root ??= owner.semanticsOwner?.rootSemanticsNode;
  });

  int? found;
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    final scrolls =
        data.hasAction(SemanticsAction.scrollUp) ||
        data.hasAction(SemanticsAction.scrollDown);
    if (scrolls && node.scrollChildCount != null) {
      found = node.scrollChildCount;
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root!);
  return found;
}

/// A paginated list that grows by a page when a row is tapped.
///
/// Also the worked example of the style-guide rule: `semanticChildCount` tracks
/// what the list currently holds, not a total from the server, so it moves with
/// `_loaded`.
class _GrowingList extends StatefulWidget {
  const _GrowingList();

  @override
  State<_GrowingList> createState() => _GrowingListState();
}

class _GrowingListState extends State<_GrowingList> {
  static const _pageSize = 20;

  int _loaded = _pageSize;

  @override
  Widget build(BuildContext context) => BgePage.slivers(
    title: const Text('paged'),
    semanticChildCount: _loaded,
    slivers: [
      SliverList.builder(
        itemCount: _loaded,
        itemBuilder: (context, index) => SizedBox(
          height: 48,
          child: TextButton(
            onPressed: () => setState(() => _loaded += _pageSize),
            child: Text('row $index'),
          ),
        ),
      ),
    ],
  );
}

void main() {
  group('BgePage content width', () {
    testWidgets('constrains the content column on a wide window', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          // A child that WANTS the full width. Measuring `Text('body')` would
          // measure its ~30px intrinsic width, which is under 480 whether or
          // not the constraint exists — that assertion passed with BgePage's
          // ConstrainedBox deleted entirely, so it tested nothing.
          const BgePage(
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // Unconstrained, a form stretches across the whole monitor and a label
      // ends up a forearm away from its input. Asserted as equality, not a
      // bound: a greedy child should be capped at exactly contentMaxWidth.
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        BgeTokens.standard.contentMaxWidth,
      );
    });

    testWidgets('is inert on a phone-width window', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(360, 800),
        ),
      );

      // 480 is wider than any phone, so the constraint must not bite. Asserted
      // by measuring rather than by "nothing threw": the greedy child should
      // get the whole window minus padding, which also proves the window is
      // actually 360 wide — the earlier version set only `MediaQueryData.size`
      // and silently ran at the 800px default.
      final padding = BgeTokens.standard.spaceLg * 2;
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        360 - padding,
      );
    });

    testWidgets('gives a pane-width page the wider measure', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            width: BgePageWidth.pane,
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // A list row is a label plus a trailing control, not a line of prose, so
      // it reads badly squeezed to the 480 form measure. Still capped, though:
      // the whole point is that no surface stretches across the monitor.
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        BgeTokens.standard.paneMaxWidth,
      );
    });

    testWidgets('is inert on a phone at pane width too', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            width: BgePageWidth.pane,
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(360, 800),
        ),
      );

      // The cap adapts by being a cap: below it, the content simply fills the
      // window. This is why the variant needs no breakpoint check — see the
      // class doc on why a threshold would have been the wrong primitive.
      final padding = BgeTokens.standard.spaceLg * 2;
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        360 - padding,
      );
    });
  });

  // ── #231 D1: the footer/FAB exclusion is a real runtime guard ──────
  //
  // It used to be an `assert`, which compiles away outside debug — so the
  // invariant was unenforced in exactly the builds users run. It is now a
  // throw on the build path, which fires in every build mode.
  //
  // Every invocation below is deliberately **non-const**. A `const`
  // invocation evaluates a constructor `assert` at compile time, so the
  // old check did hold for those — in every build mode, as a compile
  // error. The gap was only ever the non-const call, which is also the
  // shape a real screen uses (`household_list_screen.dart` builds its FAB
  // from widget state). A const invocation could not reach the runtime
  // path being tested here at all.
  //
  // These tests cannot themselves prove the release-mode behaviour: a
  // `flutter test` run always has asserts enabled. What they pin is that
  // the check is reached from `build()` rather than from the constructor,
  // which is what makes it survive to release — the `returnsNormally`
  // case fails if it ever reverts to a constructor assert.

  group('BgePage footer/floatingActionButton exclusion (#231)', () {
    testWidgets('the box constructor rejects both at once', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            footer: const SizedBox(height: 40),
            floatingActionButton: FloatingActionButton(
              onPressed: () {},
              child: const Icon(Icons.add),
            ),
            child: const Text('body'),
          ),
        ),
      );

      final error = tester.takeException();
      expect(error, isA<FlutterError>());
      expect(error.toString(), contains('Pick one'));
    });

    testWidgets('the slivers constructor rejects both at once', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage.slivers(
            footer: const SizedBox(height: 40),
            floatingActionButton: FloatingActionButton(
              onPressed: () {},
              child: const Icon(Icons.add),
            ),
            slivers: const [SliverToBoxAdapter(child: Text('body'))],
          ),
        ),
      );

      final error = tester.takeException();
      expect(error, isA<FlutterError>());
      expect(error.toString(), contains('Pick one'));
    });

    test('constructing the widget does not throw — the guard is on build', () {
      // If the check were still a constructor `assert`, this would throw
      // here and the test would fail. Construction has to stay total so the
      // guard can be a release-mode one on the build path.
      expect(
        () => BgePage(
          footer: const SizedBox(height: 40),
          floatingActionButton: FloatingActionButton(
            onPressed: () {},
            child: const Icon(Icons.add),
          ),
          child: const Text('body'),
        ),
        returnsNormally,
      );
    });

    testWidgets('a footer alone still builds', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            footer: SizedBox(key: Key('f'), height: 40),
            child: Text('body'),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('f')), findsOneWidget);
    });

    testWidgets('a floatingActionButton alone still builds', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            floatingActionButton: FloatingActionButton(
              key: Key('fab'),
              onPressed: null,
              child: Icon(Icons.add),
            ),
            child: Text('body'),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('fab')), findsOneWidget);
    });
  });

  group('BgePage footer', () {
    testWidgets('pins the footer while the content scrolls', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            footer: const SizedBox(key: Key('footer'), height: 40),
            child: Column(children: List.generate(60, (i) => Text('row $i'))),
          ),
          size: const Size(400, 600),
        ),
      );

      final before = tester.getTopLeft(find.byKey(const Key('footer'))).dy;
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();

      // A submit button that scrolls away is the failure here: on a long form
      // the action becomes unreachable without hunting for it. The footer sits
      // outside the scroll view, so scrolling must not move it.
      expect(tester.getTopLeft(find.byKey(const Key('footer'))).dy, before);
    });

    testWidgets('holds the footer to the same measure as the content', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            footer: SizedBox(
              key: Key('footer'),
              width: double.infinity,
              height: 40,
            ),
            child: SizedBox(height: 20),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // The footer belongs to the content column, not to the window. Letting
      // it span the monitor would put the submit button somewhere the eye
      // never goes — and would reintroduce the measure as a second literal.
      expect(
        tester.getSize(find.byKey(const Key('footer'))).width,
        BgeTokens.standard.contentMaxWidth,
      );
    });

    testWidgets('takes only the height it needs, not the whole cap', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            footer: const SizedBox(key: Key('footer'), height: 48),
            child: Column(children: List.generate(40, (i) => Text('row $i'))),
          ),
          size: const Size(400, 800),
        ),
      );

      // The cap bounds the footer; it must not size it. Filling the cap
      // would strand a 48dp button in the middle of a 400dp empty band and
      // squeeze the content into the top half of the window.
      final scrollHeight = tester
          .getSize(find.byType(SingleChildScrollView).first)
          .height;
      expect(scrollHeight, greaterThan(800 * 0.75));
    });

    testWidgets('keeps an oversized footer reachable at 200% text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            title: const Text('t'),
            // A note plus a button — the shape a real confirmation footer
            // takes. At 1.0 it fits; at 2.0 it is taller than the cap.
            footer: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Sending shares your device details with the server '
                  'administrator so they can reproduce the problem.',
                ),
                const BgeGap.md(),
                FilledButton(
                  key: const Key('act'),
                  onPressed: () {},
                  child: const Text('Send report'),
                ),
              ],
            ),
            child: Column(children: List.generate(20, (i) => Text('row $i'))),
          ),
          size: const Size(320, 480),
          scale: 2,
        ),
      );

      // Capping the footer alone only traded one unreachable region for
      // another: this overflowed by 450px and put the button 400dp below the
      // window, so the action was gone. The footer scrolls within its cap.
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.byKey(const Key('act')),
        find.byType(SingleChildScrollView).last,
        const Offset(0, -50),
      );
      await tester.pumpAndSettle();

      final button = tester.getRect(find.byKey(const Key('act')));
      expect(button.top, greaterThanOrEqualTo(0));
      expect(button.bottom, lessThanOrEqualTo(480));
      await tester.tap(find.byKey(const Key('act')));
    });

    testWidgets('follows the page measure on a pane page', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            width: BgePageWidth.pane,
            // Greedy, like the real thing: BgeSubmitButton defaults to
            // `expand: true`. A footer with no intrinsic width shrink-wraps,
            // exactly as the content column does.
            footer: SizedBox(
              key: Key('footer'),
              width: double.infinity,
              height: 40,
            ),
            child: SizedBox(height: 20),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // The footer follows the page's measure rather than a hardcoded one —
      // a form measure here would sit a narrow button under a wide column.
      expect(
        tester.getSize(find.byKey(const Key('footer'))).width,
        BgeTokens.standard.paneMaxWidth,
      );
    });
  });

  testWidgets('never lets a tall footer starve the content', (tester) async {
    await tester.pumpWidget(
      _host(
        tester,
        BgePage(
          title: const Text('t'),
          // A footer that wants far more room than the window has. A
          // realistic version is a note plus a button at 200% text scale
          // on a short landscape window.
          footer: const SizedBox(key: Key('footer'), height: 500),
          child: Column(children: List.generate(30, (i) => Text('row $i'))),
        ),
        size: const Size(320, 480),
        scale: 2,
      ),
    );

    // The footer sits outside the scroll view, so RenderFlex lays it out
    // first with an unbounded main axis and hands Expanded whatever is
    // left — which was zero. That collapses the scroll view and renders
    // the whole page unreachable, the exact failure this widget's scroll
    // guarantee exists to prevent.
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(SingleChildScrollView).first).height,
      greaterThan(0),
    );
  });

  group('BgePage scrolling', () {
    testWidgets('scrolls content that overflows at large text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            child: Column(children: List.generate(40, (i) => Text('row $i'))),
          ),
          size: const Size(320, 480),
          scale: 2,
        ),
      );

      // The failure mode this prevents is not cosmetic: without a scroll view,
      // the bottom of a form is permanently unreachable at the 200% text scale
      // the app guarantees.
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('scrolls even when the content fits', (tester) async {
      await tester.pumpWidget(
        _host(tester, const BgePage(child: Text('short'))),
      );

      // Scroll is not opt-in per screen; each new screen re-deciding it is how
      // one of them gets it wrong.
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });

  group('BgePage chrome', () {
    testWidgets('shows an app bar only when a title is given', (tester) async {
      await tester.pumpWidget(_host(tester, const BgePage(child: Text('b'))));
      expect(find.byType(AppBar), findsNothing);

      await tester.pumpWidget(
        _host(tester, const BgePage(title: Text('Settings'), child: Text('b'))),
      );
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('centers vertically only when asked', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(centerVertically: true, child: Text('centered')),
          size: const Size(400, 800),
        ),
      );

      final center = tester.getCenter(find.text('centered'));
      // Roughly mid-viewport rather than pinned to the top.
      expect(center.dy, greaterThan(200));
      expect(tester.takeException(), isNull);
    });
  });

  group('BgePage.slivers', () {
    testWidgets('realizes only the rows near the viewport', (tester) async {
      final built = <int>[];

      await tester.pumpWidget(
        _host(
          tester,
          BgePage.slivers(
            title: const Text('list'),
            width: BgePageWidth.pane,
            semanticChildCount: 1000,
            slivers: [
              SliverList.builder(
                itemCount: 1000,
                itemBuilder: (context, index) {
                  built.add(index);
                  return SizedBox(height: 48, child: Text('row $index'));
                },
              ),
            ],
          ),
          size: const Size(400, 300),
        ),
      );

      // The laziness half of why this constructor exists. Bounded to a
      // fraction of the list rather than an exact count: realization follows
      // the viewport and the cache extent, so pinning a number would break on
      // any row-height change. A `ListView` shrink-wrapped in `child:` under
      // an unbounded main axis builds all 1000 instead.
      expect(built.length, lessThan(100));
      // The specific claim, not just "fewer than all": a row far past the
      // fold is never touched. `lessThan(100)` alone would also pass for a
      // list that built rows 0-11 and 988-999.
      expect(built, isNot(contains(999)));

      final realizedBefore = built.length;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pump();

      // Realization keeps following the viewport rather than happening once at
      // mount — asserted by growth, because the bounds above would also hold
      // for a list that built twelve rows and then stopped working.
      expect(built.length, greaterThan(realizedBefore));
      expect(
        built.fold<int>(-1, (max, i) => i > max ? i : max),
        greaterThan(20),
      );
    });

    testWidgets('stays lazy behind a leading sliver', (tester) async {
      final built = <int>[];

      await tester.pumpWidget(
        _host(
          tester,
          BgePage.slivers(
            title: const Text('search'),
            width: BgePageWidth.pane,
            semanticChildCount: 500,
            slivers: [
              const SliverToBoxAdapter(
                child: SizedBox(height: 60, child: Text('query field')),
              ),
              SliverList.builder(
                itemCount: 500,
                itemBuilder: (context, index) {
                  built.add(index);
                  return SizedBox(height: 48, child: Text('row $index'));
                },
              ),
              const SliverToBoxAdapter(
                child: SizedBox(height: 60, child: Text('loading more')),
              ),
            ],
          ),
          size: const Size(400, 300),
        ),
      );

      // The shape a paginated search screen actually has: a field above the
      // results and a loading tail below them. Worth its own case because the
      // slivers are wrapped in a SliverMainAxisGroup — a group that measured
      // its children to place them would defeat the laziness the single-sliver
      // case above proves, and nothing else here would notice.
      expect(built.length, lessThan(100));
      expect(find.text('query field'), findsOneWidget);
    });

    testWidgets('puts the collection count on the node that scrolls', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _host(
          tester,
          BgePage.slivers(
            title: const Text('list'),
            semanticChildCount: 40,
            slivers: [
              SliverList.builder(
                itemCount: 40,
                itemBuilder: (context, index) =>
                    SizedBox(height: 48, child: Text('row $index')),
              ),
            ],
          ),
          size: const Size(400, 300),
        ),
      );

      // "Item 3 of 40". A CustomScrollView cannot infer this the way
      // `ListView(children:)` does, so the constructor passes it through — and
      // it has to arrive on the node that *scrolls*, because Android's
      // AccessibilityBridge derives CollectionInfo from that node. A count
      // stranded on a non-scrolling node is exactly the regression #191
      // shipped and #210 measured.
      expect(_countOnScrollingNode(tester), 40);

      handle.dispose();
    });

    testWidgets('holds a lazily built row to the page measure', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage.slivers(
            title: const Text('list'),
            width: BgePageWidth.pane,
            semanticChildCount: 100,
            slivers: [
              SliverList.builder(
                itemCount: 100,
                itemBuilder: (context, index) => SizedBox(
                  key: index == 0 ? const Key('greedy') : null,
                  width: double.infinity,
                  height: 48,
                ),
              ),
            ],
          ),
          size: const Size(2560, 1440),
        ),
      );

      // The box path caps its content with a ConstrainedBox around a child it
      // has in hand. The sliver path cannot: it computes a gutter from the
      // constraints and applies SliverPadding, so the cap has to hold for rows
      // that do not exist yet. Equality rather than a bound — a greedy row
      // should stop at exactly the pane measure.
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        BgeTokens.standard.paneMaxWidth,
      );
    });

    testWidgets('pins a footer over a lazy list at the same measure', (
      tester,
    ) async {
      final built = <int>[];

      await tester.pumpWidget(
        _host(
          tester,
          BgePage.slivers(
            title: const Text('list'),
            width: BgePageWidth.pane,
            semanticChildCount: 300,
            footer: const SizedBox(
              key: Key('footer'),
              width: double.infinity,
              height: 40,
            ),
            slivers: [
              SliverList.builder(
                itemCount: 300,
                itemBuilder: (context, index) {
                  built.add(index);
                  return SizedBox(
                    // Greedy, so the row reports the cap rather than the
                    // intrinsic width of a label.
                    key: index == 0 ? const Key('greedy') : null,
                    width: double.infinity,
                    height: 48,
                  );
                },
              ),
            ],
          ),
          size: const Size(2560, 1440),
        ),
      );

      // `slivers:` + `footer:` is what FeedbackReviewScreen ships, and the
      // combination is covered nowhere else: the footer branch wraps the
      // content in a LayoutBuilder + Column, so the sliver viewport computes
      // its gutter against the Expanded's constraints rather than against the
      // Scaffold body's.
      //
      // The row is what makes this case see that. A footer's width comes from
      // the footer branch's own ConstrainedBox, which never touches
      // `_sliverContent` — asserted by itself it stays green with the gutter
      // deleted, and it is already covered by 'follows the page measure on a
      // pane page'. So assert the pair, which is the claim in the name: the
      // footer lines up with the lazy content column above it.
      final rowWidth = tester.getSize(find.byKey(const Key('greedy'))).width;
      expect(rowWidth, BgeTokens.standard.paneMaxWidth);
      expect(tester.getSize(find.byKey(const Key('footer'))).width, rowWidth);
      // Laziness has to survive being nested in that Column — an Expanded
      // whose child got an unbounded main axis would realize all 300.
      expect(built.length, lessThan(100));
    });

    testWidgets('follows the count when another page arrives', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(
        _host(tester, const _GrowingList(), size: const Size(400, 300)),
      );

      expect(_countOnScrollingNode(tester), 20);

      await tester.tap(find.text('row 0'));
      await tester.pump();

      // A paginated list announces what it currently holds, so the count has
      // to survive a rebuild rather than be read once at mount. This is the
      // mechanism the style-guide rule rests on: without it a paginated caller
      // would have no way to report a growing count and would have to pass
      // null, which announces nothing at all.
      expect(_countOnScrollingNode(tester), 40);

      handle.dispose();
    });
  });
}
