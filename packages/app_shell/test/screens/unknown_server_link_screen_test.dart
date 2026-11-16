import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _title = 'Server not added';

const _body =
    "This link is for a Board Games Empire server you haven't added on this "
    "device, so it can't be opened here.";

Widget _app({ThemeData? theme}) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const UnknownServerLinkScreen()),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, _) => const Scaffold(body: Text('Home route')),
      ),
    ],
  );
  addTearDown(router.dispose);
  return MaterialApp.router(
    theme: theme,
    routerConfig: router,
    localizationsDelegates: ShellLocalizations.localizationsDelegates,
    supportedLocales: ShellLocalizations.supportedLocales,
  );
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the title and the body', (tester) async {
    await _pump(tester);

    expect(find.text(_title), findsOneWidget);
    expect(find.text(_body), findsOneWidget);
    expect(find.text('Go home'), findsOneWidget);
  });

  testWidgets('Go home goes home', (tester) async {
    await _pump(tester);

    await tester.tap(find.byKey(UnknownServerLinkScreen.homeButtonKey));
    await tester.pumpAndSettle();

    expect(find.text('Home route'), findsOneWidget);
  });

  testWidgets('the title and the body are one live region', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);

    final node = tester.getSemantics(find.text(_body));
    expect(tester.getSemantics(find.text(_title)), same(node));
    expect(node, isSemantics(isLiveRegion: true, label: '$_title\n$_body'));
    semantics.dispose();
  });

  testWidgets('Go home is focused on arrival', (tester) async {
    await _pump(tester);

    final home = Focus.of(
      tester.element(
        find.descendant(
          of: find.byKey(UnknownServerLinkScreen.homeButtonKey),
          matching: find.text('Go home'),
        ),
      ),
    );
    expect(home.hasPrimaryFocus, isTrue);
  });

  group('accessibility audit', () {
    auditScreen('ready', build: (theme) => _app(theme: theme));
  });
}
