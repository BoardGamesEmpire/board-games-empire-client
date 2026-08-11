import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
