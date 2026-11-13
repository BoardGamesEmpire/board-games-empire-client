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

/// Counts how many times it has been mounted, and can take focus on a node of
/// its own, as a section's own controls do.
class _CountsMounts extends StatefulWidget {
  const _CountsMounts({required this.onMount, this.autofocus = false});

  final VoidCallback onMount;
  final bool autofocus;

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
  Widget build(BuildContext context) =>
      Focus(autofocus: widget.autofocus, child: const SizedBox(height: 100));
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

    testWidgets('shows the welcome line only when every slot is null', (
      tester,
    ) async {
      await _pumpSections(tester);
      final context = tester.element(find.byType(HomeScreen));
      final title = ShellLocalizations.of(context).homeEmptyStateTitle;
      expect(find.text(title), findsOneWidget);
      expect(find.byKey(HomeScreen.sectionsKey), findsNothing);

      await _pumpSections(tester, somethingToPlay: _section(_toPlay));
      expect(find.text(title), findsNothing);
      expect(find.byKey(HomeScreen.sectionsKey), findsOneWidget);
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

  // The sections themselves are composed in `BgeApp`, and each is audited in
  // its own package, beside its tests (`test/home/` in events, collection and
  // catalog); this group audits the page round them (#50). The menu has its
  // own audit, in `menu_drawer_test.dart`.
  group('accessibility audit', () {
    // Every section slot null: the welcome line.
    auditScreen('empty', build: (theme) => _app(theme: theme));
  });
}
