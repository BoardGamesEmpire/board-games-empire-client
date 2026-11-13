import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Goes to the destination [id] the way a user would (#414): through the bar
/// or the rail where one shows it, otherwise through the menu, which lists
/// the destinations wherever neither shows.
Future<void> goToDestination(WidgetTester tester, String id) async {
  final control = find.byKey(NavigationShell.destinationKey(id));
  if (control.evaluate().isEmpty) return openMenuEntry(tester, id);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

/// Opens the menu and picks its entry [id], a destination's included. The
/// pick runs once the drawer has closed (#643), which the settle covers.
Future<void> openMenuEntry(WidgetTester tester, String id) async {
  await openMenu(tester);
  await tester.tap(find.byKey(MenuDrawer.entryKey(id)));
  await tester.pumpAndSettle();
}

/// Opens the navigation shell's menu: by its button, on the rail or on a
/// first page, or, on a screen the menu opened, which shows a back arrow
/// instead, the way an edge drag would.
Future<void> openMenu(WidgetTester tester) async {
  final button = find.byIcon(Icons.menu);
  if (button.evaluate().isNotEmpty) {
    await tester.tap(button);
  } else {
    tester.state<ScaffoldState>(shellScaffold).openDrawer();
  }
  await tester.pumpAndSettle();
}

/// The navigation shell's own Scaffold, which holds the menu.
final Finder shellScaffold = find
    .descendant(
      of: find.byType(NavigationShell),
      matching: find.byType(Scaffold),
    )
    .first;
