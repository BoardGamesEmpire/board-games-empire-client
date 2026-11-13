import 'dart:ui' show Tristate;

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test entries mirroring the production menu shape. Labels are literal (not
/// l10n) so the widget test stays decoupled from feature ARBs.
List<HomeMenuEntry> _entries() => [
  HomeMenuEntry(
    id: 'create_household',
    icon: Icons.group_add_outlined,
    label: 'Create household',
    onSelected: (_) {},
  ),
  HomeMenuEntry(
    id: 'send_feedback',
    icon: Icons.feedback_outlined,
    label: 'Send feedback',
    onSelected: (_) {},
  ),
  HomeMenuEntry(
    id: 'settings',
    icon: Icons.settings_outlined,
    label: 'Settings',
    onSelected: (_) {},
  ),
  HomeMenuEntry(
    id: 'sign_out',
    icon: Icons.logout,
    label: 'Sign out',
    isDestructive: true,
    onSelected: (_) {},
  ),
];

const _destinations = [
  NavDestination(
    id: 'home',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
    location: '/home',
  ),
  NavDestination(
    id: 'collection',
    icon: Icons.casino_outlined,
    selectedIcon: Icons.casino,
    label: 'Collection',
    location: '/collection',
  ),
];

/// A [MenuDrawer] in a [Scaffold]'s drawer, whose app bar gives the menu
/// button that opens it.
Widget _app({
  required List<HomeMenuEntry> entries,
  List<NavDestination> destinations = const [],
  String? selectedId,
  String? activeServerName,
  ValueChanged<HomeMenuEntry>? onEntry,
  ValueChanged<NavDestination>? onDestination,
  ThemeData? theme,
}) => MaterialApp(
  theme: theme,
  localizationsDelegates: ShellLocalizations.localizationsDelegates,
  supportedLocales: ShellLocalizations.supportedLocales,
  home: Scaffold(
    appBar: AppBar(),
    drawer: MenuDrawer(
      destinations: destinations,
      selectedId: selectedId,
      entries: entries,
      activeServerName: activeServerName,
      onDestination: onDestination ?? (_) {},
      onEntry: onEntry ?? (_) {},
    ),
    body: const SizedBox.shrink(),
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  required List<HomeMenuEntry> entries,
  List<NavDestination> destinations = const [],
  String? selectedId,
  String? activeServerName,
  ValueChanged<HomeMenuEntry>? onEntry,
  ValueChanged<NavDestination>? onDestination,
}) => tester.pumpWidget(
  _app(
    entries: entries,
    destinations: destinations,
    selectedId: selectedId,
    activeServerName: activeServerName,
    onEntry: onEntry,
    onDestination: onDestination,
  ),
);

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
}

void main() {
  group('NavDestination', () {
    test('contains its own location and what lies under it', () {
      const destination = NavDestination(
        id: 'collection',
        icon: Icons.casino_outlined,
        selectedIcon: Icons.casino,
        label: 'Collection',
        location: '/collection',
      );

      expect(destination.contains('/collection'), isTrue);
      expect(destination.contains('/collection/abc'), isTrue);
      expect(destination.contains('/collections'), isFalse);
      expect(destination.contains('/home'), isFalse);
    });
  });

  testWidgets('opens the drawer and shows every entry with its key', (
    tester,
  ) async {
    await _pump(tester, entries: _entries(), activeServerName: 'My Server');

    // Drawer starts closed.
    expect(find.byKey(MenuDrawer.entryKey('settings')), findsNothing);

    await _openDrawer(tester);

    expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
    const ids = ['create_household', 'send_feedback', 'settings', 'sign_out'];
    for (final id in ids) {
      expect(find.byKey(MenuDrawer.entryKey(id)), findsOneWidget);
    }
    expect(find.text('Create household'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  // The drawer reports a pick and does nothing else: the shell closes it and
  // runs the entry once it has closed (#414, #643).
  testWidgets('tapping an entry reports it, and neither closes the drawer nor '
      'runs it', (tester) async {
    final picked = <String>[];
    var ran = false;
    await _pump(
      tester,
      entries: [
        HomeMenuEntry(
          id: 'settings',
          icon: Icons.settings_outlined,
          label: 'Settings',
          onSelected: (_) => ran = true,
        ),
      ],
      onEntry: (entry) => picked.add(entry.id),
    );
    await _openDrawer(tester);

    await tester.tap(find.byKey(MenuDrawer.entryKey('settings')));
    await tester.pumpAndSettle();

    expect(picked, ['settings']);
    expect(ran, isFalse);
    expect(find.byKey(MenuDrawer.entryKey('settings')), findsOneWidget);
  });

  testWidgets('tapping the destructive sign-out entry reports it', (
    tester,
  ) async {
    final picked = <String>[];
    await _pump(
      tester,
      entries: _entries(),
      activeServerName: 'My Server',
      onEntry: (entry) => picked.add(entry.id),
    );
    await _openDrawer(tester);

    await tester.tap(find.byKey(MenuDrawer.entryKey('sign_out')));
    await tester.pumpAndSettle();

    expect(picked, ['sign_out']);
  });

  testWidgets('tapping a destination reports it', (tester) async {
    final picked = <String>[];
    await _pump(
      tester,
      entries: _entries(),
      destinations: _destinations,
      selectedId: 'home',
      onDestination: (destination) => picked.add(destination.id),
    );
    await _openDrawer(tester);

    await tester.tap(find.byKey(MenuDrawer.entryKey('collection')));
    await tester.pumpAndSettle();

    expect(picked, ['collection']);
  });

  testWidgets('shows the active server name in the drawer header', (
    tester,
  ) async {
    await _pump(tester, entries: _entries(), activeServerName: 'My Server');
    await _openDrawer(tester);

    expect(find.text('My Server'), findsOneWidget);
  });

  testWidgets('omits the server header when no active server is present', (
    tester,
  ) async {
    await _pump(tester, entries: _entries());
    await _openDrawer(tester);

    expect(find.text('My Server'), findsNothing);
  });

  testWidgets('destination labels reach the semantics tree', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, entries: _entries(), activeServerName: 'My Server');
    await _openDrawer(tester);

    expect(find.bySemanticsLabel(RegExp('Create household')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Sign out')), findsWidgets);

    handle.dispose();
  });

  // Opening the drawer opens a route, and a screen reader says the route's
  // name. Material names it on Android, Fuchsia, Linux and Windows, and
  // leaves it empty on iOS and macOS, so there the drawer names it itself,
  // with the same words (#50).
  testWidgets("the drawer's route is named on every platform", (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, entries: _entries());
    await _openDrawer(tester);

    final route = find.semantics.ancestor(
      of: find.semantics.byLabel(RegExp('^Create household')),
      matching: find.semantics.byFlag(SemanticsFlag.namesRoute),
    );
    final data = route.evaluate().single.getSemanticsData();
    expect(data.flagsCollection.scopesRoute, isTrue);
    expect(data.label, 'Navigation menu');

    handle.dispose();
  }, variant: TargetPlatformVariant.all());

  // The drawer's entries launch screens and fire actions, so they are
  // buttons, and a screen reader reads each by its label alone (#763).
  group('the drawer entries are not read as tabs', () {
    testWidgets('no "Tab n of m" on any entry', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, entries: _entries());
      await _openDrawer(tester);

      expect(find.bySemanticsLabel(RegExp('Create household')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'Tab \d+ of \d+')), findsNothing);

      handle.dispose();
    });

    for (final listed in [false, true]) {
      final where = listed ? 'beside destinations' : 'alone';
      for (final id in ['settings', 'sign_out']) {
        testWidgets('$id reads as a button with its label alone, and keeps '
            'focus and tap ($where)', (tester) async {
          final handle = tester.ensureSemantics();
          await _pump(
            tester,
            entries: _entries(),
            destinations: listed ? _destinations : const [],
            selectedId: listed ? 'home' : null,
          );
          await _openDrawer(tester);

          final label = id == 'settings' ? 'Settings' : 'Sign out';
          final data = find.semantics
              .byLabel(RegExp('^$label\$'))
              .evaluate()
              .single
              .getSemanticsData();
          expect(data.flagsCollection.isButton, isTrue);
          expect(data.flagsCollection.isFocused, isNot(Tristate.none));
          expect(data.hasAction(SemanticsAction.tap), isTrue);
          expect(data.hasAction(SemanticsAction.focus), isTrue);

          handle.dispose();
        });
      }
    }

    // Where the drawer lists destinations, they are its tabs, counted among
    // themselves; the entries below them are not (#414).
    testWidgets('beside destinations, only the destinations read "Tab n of '
        'm", m the number of destinations', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        entries: _entries(),
        destinations: _destinations,
        selectedId: 'home',
      );
      await _openDrawer(tester);

      final tabs = find.semantics.byLabel(RegExp(r'Tab \d+ of \d+'));
      expect(
        [for (final node in tabs.evaluate()) node.label],
        ['Home\nTab 1 of 2', 'Collection\nTab 2 of 2'],
      );

      handle.dispose();
    });
  });

  group('destinations', () {
    testWidgets('show as selectable with the selected one marked', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        entries: _entries(),
        destinations: _destinations,
        selectedId: 'collection',
      );
      await _openDrawer(tester);

      // Selectable: a selected state to say, true or false, not none.
      Tristate selected(String id) => tester
          .getSemantics(
            find.descendant(
              of: find.byKey(MenuDrawer.entryKey(id)),
              matching: find.text(id == 'home' ? 'Home' : 'Collection'),
            ),
          )
          .getSemanticsData()
          .flagsCollection
          .isSelected;

      expect(selected('collection'), Tristate.isTrue);
      expect(selected('home'), Tristate.isFalse);

      handle.dispose();
    });

    testWidgets('none selected when selectedId names none of them, or is '
        'null', (tester) async {
      for (final id in ['events', null]) {
        // A fresh drawer each time, closed until the menu button opens it.
        await tester.pumpWidget(const SizedBox.shrink());
        await _pump(
          tester,
          entries: _entries(),
          destinations: _destinations,
          selectedId: id,
        );
        await _openDrawer(tester);

        final drawer = tester.widget<NavigationDrawer>(
          find.byKey(MenuDrawer.drawerKey),
        );
        expect(drawer.selectedIndex, isNull, reason: '$id');
      }
    });

    testWidgets('no destinations, no destination divider', (tester) async {
      await _pump(tester, entries: _entries());
      await _openDrawer(tester);

      // One divider: before the destructive entries.
      expect(find.byType(Divider), findsOneWidget);

      await _pump(tester, entries: _entries(), destinations: _destinations);
      await tester.pumpAndSettle();

      // And one more after the destinations.
      expect(find.byType(Divider), findsNWidgets(2));
    });
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
    await _pump(
      tester,
      entries: _entries(),
      destinations: _destinations,
      activeServerName: 'My Server',
    );
    await _openDrawer(tester);

    double startOf(Finder f) => tester.getTopLeft(f).dx;

    final destination = startOf(
      find.descendant(
        of: find.byKey(MenuDrawer.entryKey('collection')),
        matching: find.byIcon(Icons.casino_outlined),
      ),
    );
    final entry = startOf(
      find.descendant(
        of: find.byKey(MenuDrawer.entryKey('settings')),
        matching: find.byIcon(Icons.settings_outlined),
      ),
    );
    final action = startOf(
      find.descendant(
        of: find.byKey(MenuDrawer.entryKey('sign_out')),
        matching: find.byIcon(Icons.logout),
      ),
    );
    final header = startOf(find.text('My Server'));

    expect(
      entry,
      moreOrLessEquals(destination, epsilon: 0.5),
      reason: 'entry tile icons must line up with destination icons',
    );
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

  // The Admin entry comes and goes with the session's access, which can
  // change with the drawer open (#456).
  group('entries changing under keyboard focus (#456)', () {
    /// [_entries] with an Admin entry after Send feedback, as the shell puts
    /// it, or without it.
    List<HomeMenuEntry> withAdmin({required bool admin}) {
      final entries = _entries();
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
        of: find.byKey(MenuDrawer.entryKey(id)),
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

    testWidgets('the last entry going hands focus to the one above, not '
        'to sign out', (tester) async {
      await _pump(tester, entries: _entries());
      await _openDrawer(tester);
      focusEntry(tester, 'settings');
      await tester.pump();

      await _pump(
        tester,
        entries: [
          for (final entry in _entries())
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

  // The page's own audit lives with the page; this one audits the drawer
  // (#50).
  group('accessibility audit', () {
    Widget build(ThemeData theme) => _app(
      entries: _entries(),
      destinations: _destinations,
      selectedId: 'home',
      activeServerName: 'My Server',
      theme: theme,
    );

    auditScreen('drawer open', build: build, arrange: _openDrawer);
  });
}
