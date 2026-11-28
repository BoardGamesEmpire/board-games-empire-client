import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Home with no sections.
Widget _app({ThemeData? theme}) => MaterialApp(
  theme: theme,
  localizationsDelegates: ShellLocalizations.localizationsDelegates,
  supportedLocales: ShellLocalizations.supportedLocales,
  home: const HomeScreen(),
);

const _events = Key('events_section');
const _stats = Key('stats_section');
const _newest = Key('newest_section');
const _toPlay = Key('to_play_section');

/// A section of a fixed height, which the layout gives its width.
Widget _section(Key key) => SizedBox(key: key, height: 100);

/// Home at [width], with whichever sections it's given (#613).
Future<void> _pumpSections(
  WidgetTester tester, {
  double width = 400,
  Widget? upcomingEvents,
  Widget? stats,
  Widget? newestGames,
  Widget? somethingToPlay,
  Widget? notice,
  double textScale = 1,
}) {
  useViewSize(tester, Size(width, 800));
  return tester.pumpWidget(
    MaterialApp(
      theme: BgeTheme.light(),
      localizationsDelegates: ShellLocalizations.localizationsDelegates,
      supportedLocales: ShellLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: HomeScreen(
        notice: notice,
        upcomingEvents: upcomingEvents,
        stats: stats,
        newestGames: newestGames,
        somethingToPlay: somethingToPlay,
      ),
    ),
  );
}

/// Whether a screen reader is offered the welcome line. With sections given,
/// the line stays mounted beside them and is shown only while none of them
/// draws (#1107), so being in the widget tree doesn't mean it shows. Needs
/// `tester.ensureSemantics()`.
bool _welcomeShown(WidgetTester tester) {
  final context = tester.element(find.byType(HomeScreen));
  final title = ShellLocalizations.of(context).homeEmptyStateTitle;
  // The semantics tree itself, not `find.bySemanticsLabel`: that asks each
  // widget's render object for the node it last had, which a hidden line
  // keeps.
  return find.semantics.byLabel(title).evaluate().isNotEmpty;
}

/// Counts how many times it has been mounted, and can take focus on a node of
/// its own, as a section's own controls do. It draws [child], or a section of
/// a fixed height without one.
class _CountsMounts extends StatefulWidget {
  const _CountsMounts({
    required this.onMount,
    this.autofocus = false,
    this.child,
  });

  final VoidCallback onMount;
  final bool autofocus;
  final Widget? child;

  @override
  State<_CountsMounts> createState() => _CountsMountsState();
}

class _CountsMountsState extends State<_CountsMounts> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: widget.autofocus,
    child: widget.child ?? const SizedBox(height: 100),
  );
}

void main() {
  group('sections (#613)', () {
    testWidgets('orders the sections: events, stats, newest games, something '
        'to play', (tester) async {
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: _section(_stats),
        newestGames: _section(_newest),
        somethingToPlay: _section(_toPlay),
      );

      final tops = [
        _events,
        _stats,
        _newest,
        _toPlay,
      ].map((key) => tester.getTopLeft(find.byKey(key)).dy).toList();

      expect(tops, orderedEquals(tops.toList()..sort()));
      expect(tops.toSet(), hasLength(4));
    });

    testWidgets('at 1200 wide, events and stats each take the full width, '
        'events first', (tester) async {
      await _pumpSections(
        tester,
        width: 1200,
        upcomingEvents: _section(_events),
        stats: _section(_stats),
        newestGames: _section(_newest),
      );

      final events = tester.getRect(find.byKey(_events));
      final stats = tester.getRect(find.byKey(_stats));
      final newest = tester.getRect(find.byKey(_newest));
      expect(stats.top, greaterThan(events.bottom));
      for (final section in [events, stats]) {
        expect(section.left, newest.left);
        expect(section.width, newest.width);
      }
    });

    testWidgets('null slots draw nothing and leave no gap', (tester) async {
      await _pumpSections(tester, newestGames: _section(_newest));

      final newest = tester.getRect(find.byKey(_newest));
      final sections = tester.getRect(find.byKey(HomeScreen.sectionsKey));
      expect(newest.top, sections.top);
      expect(newest.bottom, sections.bottom);
    });

    testWidgets('shows the notice above the sections', (tester) async {
      const notice = Key('notice');
      await _pumpSections(
        tester,
        notice: const SizedBox(key: notice, height: 40),
        upcomingEvents: _section(_events),
      );

      expect(
        tester.getBottomLeft(find.byKey(notice)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byKey(_events)).dy),
      );
    });

    testWidgets('sections start at the top of the page, not its middle', (
      tester,
    ) async {
      await _pumpSections(tester, upcomingEvents: _section(_events));

      // The app bar plus the page's padding, not half of a tall window.
      expect(tester.getTopLeft(find.byKey(_events)).dy, lessThan(200));
    });

    testWidgets('the sections take the wider of the page measures', (
      tester,
    ) async {
      await _pumpSections(
        tester,
        width: 2000,
        upcomingEvents: _section(_events),
      );

      final context = tester.element(find.byKey(_events));
      expect(
        tester.getSize(find.byKey(_events)).width,
        BgeTokens.of(context).paneMaxWidth,
      );
    });

    testWidgets('with every slot null, shows the welcome line and no '
        'sections', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pumpSections(tester);
      expect(_welcomeShown(tester), isTrue);
      expect(find.byKey(HomeScreen.sectionsKey), findsNothing);

      await _pumpSections(tester, somethingToPlay: _section(_toPlay));
      expect(_welcomeShown(tester), isFalse);
      expect(find.byKey(HomeScreen.sectionsKey), findsOneWidget);
      semantics.dispose();
    });

    testWidgets("a resized window keeps every section's state", (tester) async {
      final mounts = <String, int>{};
      void count(String name) => mounts[name] = (mounts[name] ?? 0) + 1;

      Future<void> pumpAt(double width) => _pumpSections(
        tester,
        width: width,
        upcomingEvents: _CountsMounts(onMount: () => count('events')),
        stats: _CountsMounts(onMount: () => count('stats')),
        newestGames: _CountsMounts(onMount: () => count('newest')),
        somethingToPlay: _CountsMounts(onMount: () => count('toPlay')),
      );

      await pumpAt(1000);
      await pumpAt(500);
      await pumpAt(1000);

      expect(mounts, {'events': 1, 'stats': 1, 'newest': 1, 'toPlay': 1});
    });

    testWidgets('a resized window keeps focus on a section', (tester) async {
      Future<void> pumpAt(double width) => _pumpSections(
        tester,
        width: width,
        upcomingEvents: _CountsMounts(onMount: () {}, autofocus: true),
        stats: _section(_stats),
      );

      await pumpAt(1000);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(
        focused?.context?.findAncestorWidgetOfExactType<_CountsMounts>(),
        isNotNull,
      );

      await pumpAt(500);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focused));

      await pumpAt(1000);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focused));
    });

    for (final (emptied, kept) in [('stats', 'events'), ('events', 'stats')]) {
      testWidgets(
        "the $emptied slot emptying keeps the $kept section's state",
        (tester) async {
          final mounts = <String, int>{};
          void count(String name) => mounts[name] = (mounts[name] ?? 0) + 1;
          Widget probe(String name) =>
              _CountsMounts(onMount: () => count(name));

          await _pumpSections(
            tester,
            upcomingEvents: probe('events'),
            stats: probe('stats'),
            newestGames: probe('newest'),
            somethingToPlay: probe('toPlay'),
          );
          await _pumpSections(
            tester,
            upcomingEvents: emptied == 'events' ? null : probe('events'),
            stats: emptied == 'stats' ? null : probe('stats'),
            newestGames: probe('newest'),
            somethingToPlay: probe('toPlay'),
          );

          // Mounted once each: none was given another's element, nor a new one.
          expect(mounts, {'events': 1, 'stats': 1, 'newest': 1, 'toPlay': 1});
          expect(find.byType(_CountsMounts), findsNWidgets(3));
        },
      );
    }

    testWidgets("a shelf emptying can't give its state to the other, of the "
        'same type', (tester) async {
      await _pumpSections(
        tester,
        newestGames: _CountsMounts(onMount: () {}),
        somethingToPlay: _CountsMounts(onMount: () {}),
      );
      final toPlay = tester.state(find.byType(_CountsMounts).last);

      await _pumpSections(
        tester,
        somethingToPlay: _CountsMounts(onMount: () {}),
      );

      expect(tester.state(find.byType(_CountsMounts)), same(toPlay));
    });

    for (final width in [320.0, 1000.0]) {
      testWidgets('holds at ${width.toInt()}dp and 2.0 text', (tester) async {
        Widget text(String label) =>
            Text('$label with a long enough name to wrap over several lines');

        await _pumpSections(
          tester,
          width: width,
          textScale: 2,
          upcomingEvents: text('Events'),
          stats: text('Stats'),
          newestGames: text('Newest'),
          somethingToPlay: text('Something'),
        );

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('a section that draws nothing takes no gap (#674)', () {
    const nothing = SizedBox.shrink();
    double xl(WidgetTester tester) =>
        BgeTokens.of(tester.element(find.byKey(HomeScreen.sectionsKey)))
            .spaceXl;
    Rect rect(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));
    // The space from the bottom of [above] to the top of [below].
    double gap(WidgetTester tester, Key above, Key below) =>
        rect(tester, below).top - rect(tester, above).bottom;

    testWidgets('drawn sections are one xl gap apart', (tester) async {
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: _section(_stats),
        newestGames: _section(_newest),
        somethingToPlay: _section(_toPlay),
      );

      final pairs = [(_events, _stats), (_stats, _newest), (_newest, _toPlay)];
      for (final (previous, next) in pairs) {
        expect(
          gap(tester, previous, next),
          xl(tester),
          reason: '$previous to $next',
        );
      }
    });

    testWidgets('a blank stats card leaves one gap between events and the '
        'shelf', (tester) async {
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: nothing,
        newestGames: _section(_newest),
        somethingToPlay: _section(_toPlay),
      );

      expect(gap(tester, _events, _newest), xl(tester));
    });

    testWidgets('a refused shelf leaves one gap between stats and something '
        'to play', (tester) async {
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: _section(_stats),
        newestGames: nothing,
        somethingToPlay: _section(_toPlay),
      );

      expect(gap(tester, _stats, _toPlay), xl(tester));
    });

    testWidgets('a last section that draws nothing leaves no gap at the end', (
      tester,
    ) async {
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: _section(_stats),
        newestGames: _section(_newest),
        somethingToPlay: nothing,
      );

      expect(
        rect(tester, HomeScreen.sectionsKey).bottom,
        rect(tester, _newest).bottom,
      );
    });

    testWidgets('a first section that draws nothing leaves no gap at the top', (
      tester,
    ) async {
      await _pumpSections(
        tester,
        upcomingEvents: nothing,
        stats: _section(_stats),
        newestGames: _section(_newest),
      );

      expect(
        rect(tester, _stats).top,
        rect(tester, HomeScreen.sectionsKey).top,
      );
    });

    testWidgets('a section that starts drawing gains its gap in the same '
        'frame, and keeps its state', (tester) async {
      final drawing = ValueNotifier(false);
      addTearDown(drawing.dispose);
      var mounts = 0;

      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: _CountsMounts(
          onMount: () => mounts++,
          child: ValueListenableBuilder(
            valueListenable: drawing,
            builder: (context, drawn, _) => drawn ? _section(_stats) : nothing,
          ),
        ),
        newestGames: _section(_newest),
      );
      expect(gap(tester, _events, _newest), xl(tester));

      drawing.value = true;
      await tester.pump();
      expect(gap(tester, _events, _stats), xl(tester));
      expect(gap(tester, _stats, _newest), xl(tester));

      drawing.value = false;
      await tester.pump();
      expect(gap(tester, _events, _newest), xl(tester));
      expect(mounts, 1);
    });

    testWidgets('paints its sections', (tester) async {
      const colour = Color(0xFF00FF00);
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: nothing,
        newestGames: const ColoredBox(
          color: colour,
          child: SizedBox(height: 100),
        ),
      );

      expect(
        tester.renderObject(find.byKey(HomeScreen.sectionsKey)),
        paints..rect(color: colour),
      );
    });

    testWidgets("a tap reaches a section's control", (tester) async {
      var tapped = 0;
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: nothing,
        newestGames: TextButton(
          onPressed: () => tapped++,
          child: const Text('See all'),
        ),
      );

      await tester.tap(find.text('See all'));
      expect(tapped, 1);
    });

    testWidgets('intrinsic and dry layout agree with layout', (tester) async {
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: nothing,
        newestGames: _section(_newest),
      );

      final box = tester.renderObject<RenderBox>(
        find.byKey(HomeScreen.sectionsKey),
      );
      final width = box.size.width;
      expect(box.size.height, 200 + xl(tester));
      expect(box.getMinIntrinsicHeight(width), box.size.height);
      expect(box.getMaxIntrinsicHeight(width), box.size.height);
      expect(
        box.getDryLayout(BoxConstraints(maxWidth: width)).height,
        box.size.height,
      );
    });

    testWidgets('dry and laid-out baselines agree', (tester) async {
      await _pumpSections(
        tester,
        upcomingEvents: _section(_events),
        stats: nothing,
        newestGames: const Text('Recently added'),
        // A section that can't be dry laid out, as the shelves can't: the
        // dry baseline must stop at the text and never ask it.
        somethingToPlay: LayoutBuilder(
          builder: (context, constraints) => const SizedBox(height: 100),
        ),
      );

      final box = tester.renderObject<RenderBox>(
        find.byKey(HomeScreen.sectionsKey),
      );
      final text = tester.renderObject<RenderBox>(find.text('Recently added'));
      const alphabetic = TextBaseline.alphabetic;
      // Only a parent laying a box out may ask for its baseline; this lifts
      // that check as the framework's own intrinsic checks do.
      final double? baseline;
      final double textBaseline;
      RenderObject.debugCheckingIntrinsics = true;
      try {
        baseline = box.getDistanceToBaseline(alphabetic);
        textBaseline = text.getDistanceToBaseline(alphabetic)!;
      } finally {
        RenderObject.debugCheckingIntrinsics = false;
      }
      // The first section with a baseline is the text, one gap below events.
      expect(baseline, 100 + xl(tester) + textBaseline);
      expect(
        box.getDryBaseline(
          BoxConstraints(maxWidth: box.size.width),
          alphabetic,
        ),
        baseline,
      );
    });
  });

  group('every section drawing nothing shows the welcome line (#1107)', () {
    const nothing = SizedBox.shrink();
    // What holds the sections and, in their place, the welcome line.
    RenderBox content(WidgetTester tester) =>
        tester.renderObject(find.byKey(HomeScreen.sectionsKey)).parent!
            as RenderBox;

    testWidgets('shows the welcome line when no section draws', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpSections(
        tester,
        stats: nothing,
        newestGames: nothing,
        somethingToPlay: nothing,
      );

      expect(_welcomeShown(tester), isTrue);
      expect(content(tester), paints..paragraph());
      expect(tester.getSize(find.byKey(HomeScreen.sectionsKey)).height, 0);
      // A pointer on the line reaches it, as a text selection's would.
      final title = find.text(
        ShellLocalizations.of(
          tester.element(find.byType(HomeScreen)),
        ).homeEmptyStateTitle,
      );
      final hit = tester.hitTestOnBinding(tester.getCenter(title));
      expect(
        hit.path.map((entry) => entry.target),
        contains(tester.renderObject(title)),
      );
      semantics.dispose();
    });

    testWidgets('hides the welcome line while a section draws', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pumpSections(
        tester,
        stats: nothing,
        newestGames: _section(_newest),
        somethingToPlay: nothing,
      );

      expect(_welcomeShown(tester), isFalse);
      expect(content(tester), isNot(paints..paragraph()));
      expect(content(tester).size.height, 100);
      semantics.dispose();
    });

    testWidgets('a section that starts drawing replaces the welcome line in '
        'the same frame, and keeps its state', (tester) async {
      final semantics = tester.ensureSemantics();
      final drawing = ValueNotifier(false);
      addTearDown(drawing.dispose);
      var mounts = 0;

      await _pumpSections(
        tester,
        stats: _CountsMounts(
          onMount: () => mounts++,
          child: ValueListenableBuilder(
            valueListenable: drawing,
            builder: (context, drawn, _) => drawn ? _section(_stats) : nothing,
          ),
        ),
        newestGames: nothing,
      );
      expect(_welcomeShown(tester), isTrue);

      drawing.value = true;
      await tester.pump();
      expect(_welcomeShown(tester), isFalse);
      expect(content(tester), isNot(paints..paragraph()));
      expect(
        tester.getRect(find.byKey(_stats)),
        tester.getRect(find.byKey(HomeScreen.sectionsKey)),
      );

      drawing.value = false;
      await tester.pump();
      expect(_welcomeShown(tester), isTrue);
      expect(mounts, 1);
      semantics.dispose();
    });

    testWidgets("a tap reaches a section's control over the welcome line's "
        'place', (tester) async {
      var tapped = 0;
      await _pumpSections(
        tester,
        stats: nothing,
        newestGames: TextButton(
          onPressed: () => tapped++,
          child: const Text('See all'),
        ),
      );

      await tester.tap(find.text('See all'));
      expect(tapped, 1);
    });

    for (final blank in [true, false]) {
      testWidgets('intrinsic and dry layout agree with layout, '
          '${blank ? 'showing' : 'hiding'} the welcome line', (tester) async {
        await _pumpSections(
          tester,
          stats: nothing,
          newestGames: blank ? nothing : _section(_newest),
        );

        final box = content(tester);
        final width = box.size.width;
        expect(box.size.height, greaterThan(0));
        expect(box.getMinIntrinsicHeight(width), box.size.height);
        expect(box.getMaxIntrinsicHeight(width), box.size.height);
        expect(
          box.getDryLayout(BoxConstraints.tightFor(width: width)).height,
          box.size.height,
        );
      });

      testWidgets('dry and laid-out baselines agree, '
          '${blank ? 'showing' : 'hiding'} the welcome line', (tester) async {
        await _pumpSections(
          tester,
          stats: nothing,
          newestGames: blank ? nothing : const Text('Recently added'),
        );

        final box = content(tester);
        const alphabetic = TextBaseline.alphabetic;
        // Only a parent laying a box out may ask for its baseline; this lifts
        // that check as the framework's own intrinsic checks do.
        final double? baseline;
        RenderObject.debugCheckingIntrinsics = true;
        try {
          baseline = box.getDistanceToBaseline(alphabetic);
        } finally {
          RenderObject.debugCheckingIntrinsics = false;
        }
        expect(baseline, isNotNull);
        expect(
          box.getDryBaseline(
            BoxConstraints.tightFor(width: box.size.width),
            alphabetic,
          ),
          baseline,
        );
      });
    }
  });

  // The sections themselves are composed in `BgeApp`, and each is audited in
  // its own package, beside its tests (`test/home/` in events, collection and
  // catalog); this group audits the page round them (#50). The menu has its
  // own audit, in `menu_drawer_test.dart`.
  group('accessibility audit', () {
    // Every section slot null: the welcome line.
    auditScreen('empty', build: (theme) => _app(theme: theme));
    // Every section given draws nothing: the welcome line in their place
    // (#1107).
    auditScreen(
      'every section blank',
      build: (theme) => MaterialApp(
        theme: theme,
        localizationsDelegates: ShellLocalizations.localizationsDelegates,
        supportedLocales: ShellLocalizations.supportedLocales,
        home: const HomeScreen(
          newestGames: SizedBox.shrink(),
          somethingToPlay: SizedBox.shrink(),
        ),
      ),
    );
  });

  group('header action (#475)', () {
    const action = Key('header_action');

    testWidgets('shows the header action at the end of the app bar', (
      tester,
    ) async {
      useViewSize(tester, const Size(400, 800));
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates: ShellLocalizations.localizationsDelegates,
          supportedLocales: ShellLocalizations.supportedLocales,
          home: const HomeScreen(
            headerAction: SizedBox(key: action, width: 48, height: 48),
          ),
        ),
      );

      final bar = tester.getRect(find.byType(AppBar));
      final rect = tester.getRect(
        find.descendant(of: find.byType(AppBar), matching: find.byKey(action)),
      );
      expect(rect.size, const Size(48, 48));
      expect(rect.right, greaterThan(bar.right - 16));
    });

    testWidgets('shows nothing there without one', (tester) async {
      await tester.pumpWidget(_app());

      expect(find.byKey(action), findsNothing);
    });
  });
}
