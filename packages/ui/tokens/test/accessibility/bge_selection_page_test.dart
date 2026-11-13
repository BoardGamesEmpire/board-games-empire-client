import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectionRegistrar;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A page whose state shows whether it was kept or built afresh.
class _Page extends StatefulWidget {
  const _Page(this.label);

  final String label;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  Widget build(BuildContext context) => Text(widget.label);
}

/// A page whose body scrolls, as most of the app's do: a [Scrollable]
/// puts a selection container of its own under the page's scope.
class _ScrollingPage extends StatefulWidget {
  const _ScrollingPage(this.label);

  final String label;

  @override
  State<_ScrollingPage> createState() => _ScrollingPageState();
}

class _ScrollingPageState extends State<_ScrollingPage> {
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      children: [
        Text('${widget.label} one'),
        Text('${widget.label} two'),
        Text('${widget.label} three'),
      ],
    ),
  );
}

void main() {
  Page<void> page(String label) => MaterialPage<void>(
    key: ValueKey(label),
    child: BgeSelectionPage(child: _Page(label)),
  );

  Page<void> scrolling(String label) => MaterialPage<void>(
    key: ValueKey(label),
    child: BgeSelectionPage(child: _ScrollingPage(label)),
  );

  /// Hosts a Navigator under the app-wide region, where `BgeApp` puts it,
  /// showing [pages] until [show] changes them.
  Future<void> pumpPages(
    WidgetTester tester,
    TargetPlatform platform,
    ValueNotifier<List<Page<void>>> show,
  ) => tester.pumpWidget(
    MaterialApp(
      theme: BgeTheme.light().copyWith(platform: platform),
      builder: (context, child) => BgeSelectionRegion(child: child!),
      home: ValueListenableBuilder(
        valueListenable: show,
        builder: (context, pages, _) =>
            Navigator(pages: pages, onDidRemovePage: (_) {}),
      ),
    ),
  );

  /// What the region hands the pages beneath it.
  SelectionRegistrar regionOf(WidgetTester tester) =>
      SelectionContainer.maybeOf(
        tester.element(find.byType(Navigator).first),
      )!;

  /// The registrar [label]'s page hands its text.
  SelectionRegistrar? registrarOf(WidgetTester tester, String label) =>
      SelectionContainer.maybeOf(
        tester.element(
          find.byWidgetPredicate(
            (widget) => widget is _Page && widget.label == label,
            skipOffstage: false,
          ),
        ),
      );

  group('BgeSelectionPage', () {
    // A page added beneath the top one in the same change, as a browser
    // Back to a pushed page rebuilds the stack (#611), is built but never
    // laid out. Its text, registered with the region, broke the region's
    // screen-order sort on the next frame.
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      testWidgets('$platform: a page added beneath the top one in the same '
          'change breaks nothing', (tester) async {
        final show = ValueNotifier([page('A')]);
        addTearDown(show.dispose);
        await pumpPages(tester, platform, show);

        show.value = [page('B'), page('C')];
        await tester.pumpAndSettle();

        expect(find.text('C'), findsOneWidget);
        expect(registrarOf(tester, 'B'), isNot(regionOf(tester)));
      });

      // The scroll view's own container sorted the hidden page's text
      // whatever registrar the page handed it, so until it has shown the
      // page hands none, and the scroll view makes no container.
      testWidgets('$platform: a page with a scrolling body added beneath the '
          'top one breaks nothing, and joins the region once it shows', (
        tester,
      ) async {
        final show = ValueNotifier([page('A')]);
        addTearDown(show.dispose);
        await pumpPages(tester, platform, show);

        show.value = [scrolling('B'), page('C')];
        await tester.pumpAndSettle();
        expect(find.text('C'), findsOneWidget);
        final hidden = tester.state(
          find.byType(_ScrollingPage, skipOffstage: false),
        );

        show.value = [scrolling('B')];
        await tester.pumpAndSettle();

        expect(find.text('B two'), findsOneWidget);
        // The page itself is kept: only what is beneath its scroll view is
        // built again, and nobody had seen it.
        expect(tester.state(find.byType(_ScrollingPage)), same(hidden));
        expect(
          SelectionContainer.maybeOf(tester.element(find.text('B two'))),
          isNotNull,
        );
      });
    }

    testWidgets('a page that has shown keeps its scroll view whole when '
        'covered and shown again', (tester) async {
      final show = ValueNotifier([scrolling('A')]);
      addTearDown(show.dispose);
      await pumpPages(tester, TargetPlatform.macOS, show);
      final beneath = tester.element(find.text('A two'));

      show.value = [scrolling('A'), page('B')];
      await tester.pumpAndSettle();
      show.value = [scrolling('A')];
      await tester.pumpAndSettle();

      expect(tester.element(find.text('A two')), same(beneath));
    });

    testWidgets('a hidden page rejoins the region once it shows, and is not '
        'rebuilt from scratch', (tester) async {
      final show = ValueNotifier([page('A')]);
      addTearDown(show.dispose);
      await pumpPages(tester, TargetPlatform.macOS, show);
      final state = tester.state(find.byType(_Page));
      expect(registrarOf(tester, 'A'), same(regionOf(tester)));

      show.value = [page('A'), page('B')];
      await tester.pumpAndSettle();
      expect(registrarOf(tester, 'A'), isNot(regionOf(tester)));
      expect(registrarOf(tester, 'B'), same(regionOf(tester)));

      show.value = [page('A')];
      await tester.pumpAndSettle();
      expect(registrarOf(tester, 'A'), same(regionOf(tester)));
      expect(tester.state(find.byType(_Page)), same(state));
    });

    testWidgets('with no region above, it adds nothing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: BgeSelectionPage(child: Text('A'))),
      );

      expect(
        find.descendant(
          of: find.byType(BgeSelectionPage),
          matching: find.byType(SelectionRegistrarScope),
        ),
        findsNothing,
      );
    });
  });
}
