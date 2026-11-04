import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Test entries mirroring the production menu shape; each records its id so
/// the tests can assert the tapped tile's action fired. Labels are literal
/// (not l10n) so the widget test stays decoupled from feature ARBs.
List<HomeMenuEntry> _entries(List<String> taps) => [
  HomeMenuEntry(
    id: 'create_household',
    icon: Icons.group_add_outlined,
    label: 'Create household',
    onSelected: (_) => taps.add('create_household'),
  ),
  HomeMenuEntry(
    id: 'send_feedback',
    icon: Icons.feedback_outlined,
    label: 'Send feedback',
    onSelected: (_) => taps.add('send_feedback'),
  ),
  HomeMenuEntry(
    id: 'settings',
    icon: Icons.settings_outlined,
    label: 'Settings',
    onSelected: (_) => taps.add('settings'),
  ),
  HomeMenuEntry(
    id: 'sign_out',
    icon: Icons.logout,
    label: 'Sign out',
    isDestructive: true,
    onSelected: (_) => taps.add('sign_out'),
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  required List<HomeMenuEntry> entries,
  String? activeServerName,
}) {
  return tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: ShellLocalizations.localizationsDelegates,
      supportedLocales: ShellLocalizations.supportedLocales,
      home: HomeScreen(entries: entries, activeServerName: activeServerName),
    ),
  );
}

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
        entries: const [],
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

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens the drawer and shows every entry with its key', (
    tester,
  ) async {
    await _pump(tester, entries: _entries([]), activeServerName: 'My Server');

    // Drawer starts closed.
    expect(find.byKey(HomeScreen.entryKey('settings')), findsNothing);

    await _openDrawer(tester);

    expect(find.byKey(HomeScreen.drawerKey), findsOneWidget);
    const ids = ['create_household', 'send_feedback', 'settings', 'sign_out'];
    for (final id in ids) {
      expect(find.byKey(HomeScreen.entryKey(id)), findsOneWidget);
    }
    expect(find.text('Create household'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets(
    'tapping a destination invokes its action and closes the drawer',
    (tester) async {
      final taps = <String>[];
      await _pump(
        tester,
        entries: _entries(taps),
        activeServerName: 'My Server',
      );
      await _openDrawer(tester);

      await tester.tap(find.byKey(HomeScreen.entryKey('settings')));
      await tester.pumpAndSettle();

      expect(taps, ['settings']);
      // Drawer closed → its entries leave the tree.
      expect(find.byKey(HomeScreen.entryKey('settings')), findsNothing);
    },
  );

  testWidgets('tapping the destructive sign-out entry invokes its action', (
    tester,
  ) async {
    final taps = <String>[];
    await _pump(tester, entries: _entries(taps), activeServerName: 'My Server');
    await _openDrawer(tester);

    await tester.tap(find.byKey(HomeScreen.entryKey('sign_out')));
    await tester.pumpAndSettle();

    expect(taps, ['sign_out']);
  });

  testWidgets('shows the active server name in the drawer header', (
    tester,
  ) async {
    await _pump(tester, entries: _entries([]), activeServerName: 'My Server');
    await _openDrawer(tester);

    expect(find.text('My Server'), findsOneWidget);
  });

  testWidgets('omits the server header when no active server is present', (
    tester,
  ) async {
    await _pump(tester, entries: _entries([]));
    await _openDrawer(tester);

    expect(find.text('My Server'), findsNothing);
  });

  testWidgets('destination labels reach the semantics tree', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, entries: _entries([]), activeServerName: 'My Server');
    await _openDrawer(tester);

    expect(find.bySemanticsLabel(RegExp('Create household')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Sign out')), findsWidgets);

    handle.dispose();
  });

  testWidgets('drawer header, destinations, and actions share one start '
      'inset', (tester) async {
    // This drifted silently once already. The token sweep moved the header
    // and divider to 24 and the action tiles to 8+16=24, while the
    // destinations stayed at Flutter's default tilePadding 12 + a fixed 16
    // internal gutter = 28. Nothing failed; the drawer just stopped lining up.
    //
    // Asserted on rendered geometry rather than on the padding values,
    // because the destinations' 16dp gutter is internal to Flutter and not
    // visible from this side — only the resulting edge is.
    await _pump(tester, entries: _entries([]), activeServerName: 'My Server');
    await _openDrawer(tester);

    double startOf(Finder f) => tester.getTopLeft(f).dx;

    final destination = startOf(
      find.descendant(
        of: find.byKey(HomeScreen.entryKey('settings')),
        matching: find.byIcon(Icons.settings_outlined),
      ),
    );
    final action = startOf(
      find.descendant(
        of: find.byKey(HomeScreen.entryKey('sign_out')),
        matching: find.byIcon(Icons.logout),
      ),
    );
    final header = startOf(find.text('My Server'));

    expect(
      action,
      moreOrLessEquals(destination, epsilon: 0.5),
      reason: 'action tile icons must line up with destination icons',
    );
    expect(
      header,
      moreOrLessEquals(destination, epsilon: 0.5),
      reason: 'the header must line up with the destinations below it',
    );
  });

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
        'the $emptied slot emptying keeps the $kept section\'s state',
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

  // The Admin entry comes and goes with the session's access, which can
  // change with the drawer open (#456).
  group('entries changing under keyboard focus (#456)', () {
    /// [_entries] with an Admin entry after Send feedback, as the shell puts
    /// it, or without it.
    List<HomeMenuEntry> withAdmin({required bool admin}) {
      final entries = _entries([]);
      return [
        ...entries.take(2),
        if (admin)
          HomeMenuEntry(
            id: 'admin',
            icon: Icons.admin_panel_settings_outlined,
            label: 'Admin',
            onSelected: (_) {},
          ),
        ...entries.skip(2),
      ];
    }

    void focusEntry(WidgetTester tester, String id) {
      final label = find.descendant(
        of: find.byKey(HomeScreen.entryKey(id)),
        matching: find.byType(Text),
      );
      Focus.of(tester.element(label.first)).requestFocus();
    }

    /// The id of the entry holding focus, or null for none.
    String? focusedEntry() {
      String? found;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
        final key = e.widget.key;
        if (key is ValueKey<String> &&
            key.value.startsWith('home_menu_entry_')) {
          found = key.value.substring('home_menu_entry_'.length);
        }
        return found == null;
      });
      return found;
    }

    Future<void> openWithFocusOn(WidgetTester tester, String id) async {
      await _pump(tester, entries: withAdmin(admin: true));
      await _openDrawer(tester);
      focusEntry(tester, id);
      await tester.pump();
      expect(focusedEntry(), id);
    }

    testWidgets('an entry that goes with focus hands it to the one that takes '
        'its place', (tester) async {
      await openWithFocusOn(tester, 'admin');

      await _pump(tester, entries: withAdmin(admin: false));
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
      expect(focusedEntry(), 'settings');
    });

    for (final below in ['settings', 'sign_out']) {
      testWidgets('an entry below one that goes keeps focus ($below)', (
        tester,
      ) async {
        await openWithFocusOn(tester, below);

        await _pump(tester, entries: withAdmin(admin: false));
        await tester.pumpAndSettle();

        expect(
          FocusManager.instance.primaryFocus,
          isNot(isA<FocusScopeNode>()),
        );
        expect(focusedEntry(), below);
      });
    }

    testWidgets('the last destination going hands focus to the one above, not '
        'to sign out', (tester) async {
      await _pump(tester, entries: _entries([]));
      await _openDrawer(tester);
      focusEntry(tester, 'settings');
      await tester.pump();

      await _pump(
        tester,
        entries: [
          for (final entry in _entries([]))
            if (entry.id != 'settings') entry,
        ],
      );
      await tester.pumpAndSettle();

      expect(focusedEntry(), 'send_feedback');
    });

    testWidgets('focus on an entry above the change is left alone', (
      tester,
    ) async {
      await openWithFocusOn(tester, 'send_feedback');
      final focused = FocusManager.instance.primaryFocus;

      await _pump(tester, entries: withAdmin(admin: false));
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(focused));
    });

    testWidgets('focus outside the drawer is left alone', (tester) async {
      await _pump(tester, entries: withAdmin(admin: true));
      final menu = find.byIcon(Icons.menu);
      Focus.of(tester.element(menu)).requestFocus();
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;

      await _pump(tester, entries: withAdmin(admin: false));
      await tester.pumpAndSettle();

      expect(FocusManager.instance.primaryFocus, same(focused));
    });
  });
}
