import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/deep_links/server_link_address.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _title = 'Server not added';

const _body =
    "This link is for a Board Games Empire server you haven't added on this "
    "device, so it can't be opened here.";

const _bodyAt =
    'This link is for a Board Games Empire server at '
    'games.example.org:8443/bge, '
    "which you haven't added on this device.";

/// A link whose address names a host, a port and a path prefix (#971).
final ServerDeepLink _linkWithAddress = serverDeepLinkFromLocation(
  '/server/srv-1/event/ev-1'
  '?address=https%3A%2F%2Fgames.example.org%3A8443%2Fbge',
)!;

/// A link that carries no address.
final ServerDeepLink _linkWithoutAddress = serverDeepLinkFromLocation(
  '/server/srv-1/event/ev-1',
)!;

/// The router state `/servers/add` was opened with, in the harness.
Uri? _addedWith;

Widget _app({ServerDeepLink? link, ThemeData? theme}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => UnknownServerLinkScreen(link: link),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, _) => const Scaffold(body: Text('Home route')),
      ),
      // Nested as the app nests it, so a push of the child is what the
      // screen's push is in the app.
      GoRoute(
        path: AppRoutes.servers,
        builder: (_, _) => const Scaffold(body: Text('Servers route')),
        routes: [
          GoRoute(
            path: 'add',
            builder: (_, state) {
              _addedWith = state.uri;
              return const Scaffold(body: Text('Add route'));
            },
          ),
        ],
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

Future<void> _pump(WidgetTester tester, {ServerDeepLink? link}) async {
  await tester.pumpWidget(_app(link: link));
  await tester.pumpAndSettle();
}

FocusNode _focusOf(WidgetTester tester, Key key, String label) => Focus.of(
  tester.element(
    find.descendant(of: find.byKey(key), matching: find.text(label)),
  ),
);

void main() {
  setUp(() => _addedWith = null);

  group('without an address', () {
    for (final (name, link) in [
      ('no link', null),
      ('a link with no address', _linkWithoutAddress),
    ]) {
      group(name, () {
        testWidgets('shows the title and the body', (tester) async {
          await _pump(tester, link: link);

          expect(find.text(_title), findsOneWidget);
          expect(find.text(_body), findsOneWidget);
          expect(find.text('Go home'), findsOneWidget);
          expect(
            find.byKey(UnknownServerLinkScreen.addButtonKey),
            findsNothing,
          );
          expect(find.byType(FilledButton), findsOneWidget);
          expect(find.byType(OutlinedButton), findsNothing);
        });

        testWidgets('Go home is focused on arrival', (tester) async {
          await _pump(tester, link: link);

          final home = _focusOf(
            tester,
            UnknownServerLinkScreen.homeButtonKey,
            'Go home',
          );
          expect(home.hasPrimaryFocus, isTrue);
        });
      });
    }
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

  group('with an address (#971)', () {
    testWidgets('names its address and offers the add', (tester) async {
      await _pump(tester, link: _linkWithAddress);

      expect(find.text(_title), findsOneWidget);
      expect(find.text(_bodyAt), findsOneWidget);
      expect(find.byKey(UnknownServerLinkScreen.addButtonKey), findsOneWidget);
      expect(find.text('Add this server'), findsOneWidget);
      expect(find.byKey(UnknownServerLinkScreen.homeButtonKey), findsOneWidget);
    });

    // `Uri.host` drops an IPv6 literal's brackets, which would read as a
    // different address with no port.
    testWidgets('names an IPv6 host in brackets, with its port', (
      tester,
    ) async {
      final link = serverDeepLinkFromLocation(
        '/server/srv-1/event/ev-1'
        '?address=https%3A%2F%2F%5B2001%3Adb8%3A%3A1%5D%3A8443%2Fbge',
      );
      expect(link?.address, isNotNull);
      await _pump(tester, link: link);

      expect(
        find.textContaining(' at [2001:db8::1]:8443/bge, '),
        findsOneWidget,
      );
    });

    testWidgets('leaves out a default port', (tester) async {
      final link = serverDeepLinkFromLocation(
        '/server/srv-1/event/ev-1'
        '?address=https%3A%2F%2Fgames.example.org%2Fbge',
      );
      expect(link?.address, isNotNull);
      await _pump(tester, link: link);

      expect(
        find.textContaining(' at games.example.org/bge, '),
        findsOneWidget,
      );
    });

    // Servers can share a host under different prefixes, so the prefix is
    // what tells them apart; a server at the root has none to show.
    testWidgets('names a server at the root by its host alone', (
      tester,
    ) async {
      final link = serverDeepLinkFromLocation(
        '/server/srv-1/event/ev-1'
        '?address=https%3A%2F%2Fgames.example.org%2F',
      );
      expect(link?.address, isNotNull);
      await _pump(tester, link: link);

      expect(find.textContaining(' at games.example.org, '), findsOneWidget);
    });

    testWidgets('the title and the address are one live region', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, link: _linkWithAddress);

      final node = tester.getSemantics(find.text(_bodyAt));
      expect(tester.getSemantics(find.text(_title)), same(node));
      expect(
        node,
        isSemantics(isLiveRegion: true, label: '$_title\n$_bodyAt'),
      );
      semantics.dispose();
    });

    testWidgets('the add is focused on arrival', (tester) async {
      await _pump(tester, link: _linkWithAddress);

      final add = _focusOf(
        tester,
        UnknownServerLinkScreen.addButtonKey,
        'Add this server',
      );
      expect(add.hasPrimaryFocus, isTrue);
      // The add is the primary action; Go home is the secondary one below.
      expect(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.text('Add this server'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(OutlinedButton),
          matching: find.text('Go home'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('Go home')).dy,
        greaterThan(tester.getTopLeft(find.text('Add this server')).dy),
      );
    });

    testWidgets('Go home still goes home', (tester) async {
      await _pump(tester, link: _linkWithAddress);

      await tester.tap(find.byKey(UnknownServerLinkScreen.homeButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Home route'), findsOneWidget);
    });

    testWidgets('Add this server opens the add route with the link', (
      tester,
    ) async {
      await _pump(tester, link: _linkWithAddress);

      await tester.tap(find.byKey(UnknownServerLinkScreen.addButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Add route'), findsOneWidget);
      expect(_addedWith?.path, AppRoutes.serversAdd);
      expect(
        _addedWith?.queryParameters[AppRoutes.deepLinkParam],
        _linkWithAddress.location,
      );

      // Back returns to the screen, its address still shown, and keyboard
      // focus back on the add.
      GoRouter.of(tester.element(find.text('Add route'))).pop();
      await tester.pumpAndSettle();

      expect(find.text('Add route'), findsNothing);
      expect(find.text('Servers route'), findsNothing);
      expect(find.text(_bodyAt), findsOneWidget);
      final add = _focusOf(
        tester,
        UnknownServerLinkScreen.addButtonKey,
        'Add this server',
      );
      expect(add.hasPrimaryFocus, isTrue);
    });
  });

  group('accessibility audit', () {
    auditScreen('ready', build: (theme) => _app(theme: theme));
    auditScreen(
      'with an address',
      build: (theme) => _app(link: _linkWithAddress, theme: theme),
    );
  });
}
