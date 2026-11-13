import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _home = NavDestination(
  id: 'home',
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  label: 'Home',
  location: '/home',
);
const _collection = NavDestination(
  id: 'collection',
  icon: Icons.casino_outlined,
  selectedIcon: Icons.casino,
  label: 'Collection',
  location: '/collection',
);
const _games = NavDestination(
  id: 'games',
  icon: Icons.explore_outlined,
  selectedIcon: Icons.explore,
  label: 'Games',
  location: '/games',
);
const _events = NavDestination(
  id: 'events',
  icon: Icons.event_outlined,
  selectedIcon: Icons.event,
  label: 'Events',
  location: '/events',
);

/// The app's four destinations, in the app's order.
const List<NavDestination> _destinations = [
  _home,
  _collection,
  _games,
  _events,
];

/// A signed-in page as the app builds one: a `BgePage` with a floating
/// button, so the SnackBar test has a FAB to watch. Stateful, so a test can
/// tell a kept page from a rebuilt one by its `State`.
class _Page extends StatefulWidget {
  const _Page(this.name);

  static Key bodyKey(String name) => ValueKey('body:$name');
  static Key fabKey(String name) => ValueKey('fab:$name');

  final String name;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  @override
  Widget build(BuildContext context) => BgePage(
    title: Text('Page ${widget.name}'),
    floatingActionButton: FloatingActionButton(
      key: _Page.fabKey(widget.name),
      heroTag: null,
      tooltip: 'Add',
      onPressed: () {},
      child: const Icon(Icons.add),
    ),
    child: Text(
      'The body of ${widget.name}',
      key: _Page.bodyKey(widget.name),
    ),
  );
}

/// The shell under a real router, with the routes a test drives.
class _Harness {
  _Harness(this.tester, this.router, this.runs);

  final WidgetTester tester;
  final GoRouter router;

  /// Each menu entry's id, once per time its action ran.
  final List<String> runs;

  String get location => router.state.uri.path;

  /// The shell's own Scaffold: the outermost one.
  ScaffoldState get scaffold =>
      tester.firstState<ScaffoldState>(find.byType(Scaffold));

  MenuDrawer get drawer => tester.widget<MenuDrawer>(find.byType(MenuDrawer));

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  Future<void> push(String location) async {
    unawaited(router.push<void>(location));
    await tester.pumpAndSettle();
  }

  Future<void> openMenu() async {
    scaffold.openDrawer();
    await tester.pumpAndSettle();
  }

  /// System Back, as Android delivers it. Returns whether anything took it.
  Future<bool> back() async {
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    return handled;
  }

  Future<void> resize(Size size) async {
    tester.view.physicalSize = size;
    await tester.pumpAndSettle();
  }

  /// The [_Page] showing [name], built or not.
  State<_Page> page(String name) => tester.state<State<_Page>>(
    find.byWidgetPredicate(
      (widget) => widget is _Page && widget.name == name,
      skipOffstage: false,
    ),
  );
}

List<HomeMenuEntry> _entries(List<String> runs) => [
  // Opens its screen by location: the shell pushes it.
  const HomeMenuEntry(
    id: 'feedback',
    icon: Icons.feedback_outlined,
    label: 'Feedback',
    location: '/feedback',
  ),
  HomeMenuEntry(
    id: 'households',
    icon: Icons.groups_outlined,
    label: 'Households',
    onSelected: (_) => runs.add('households'),
  ),
  HomeMenuEntry(
    id: 'settings',
    icon: Icons.settings_outlined,
    label: 'Settings',
    // The shell's own context: under the router, so a push resolves.
    onSelected: (context) {
      runs.add('settings');
      unawaited(context.push('/settings'));
    },
  ),
  HomeMenuEntry(
    id: 'sign_out',
    icon: Icons.logout,
    label: 'Sign out',
    isDestructive: true,
    onSelected: (_) => runs.add('sign_out'),
  ),
];

Page<void> _material(GoRouterState state) => MaterialPage<void>(
  key: state.pageKey,
  child: _Page(state.uri.path),
);

/// Hosts the shell as a `ShellRoute` builder, the way the app's router
/// will, at [size] (#414).
///
/// Home is a `NoTransitionPage` and everything else a `MaterialPage`, as
/// the app builds them. [underRegion] puts the app's selection region
/// above the router and a pointer platform in the theme, as `BgeApp` has
/// them on desktop and web (#338). [platform] goes in the theme, where the
/// shell and the page transitions read it.
/// [inOuterShell] puts the shell's route inside another `ShellRoute`, as
/// the app's auth shell holds it.
Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = const Size(400, 800),
  String at = '/home',
  List<NavDestination> destinations = _destinations,
  double textScale = 1,
  bool underRegion = false,
  TargetPlatform? platform,
  TextDirection textDirection = TextDirection.ltr,
  bool Function()? deferBack,
  ThemeData? themeData,
  GlobalKey? boundary,
  bool inOuterShell = false,
}) async {
  final theme =
      themeData ?? (underRegion ? pointerPlatformTheme() : BgeTheme.light());
  useViewSize(tester, size);
  final runs = <String>[];
  final entries = _entries(runs);
  final RouteBase shell = ShellRoute(
    builder: (context, state, child) => NavigationShell(
      destinations: destinations,
      entries: entries,
      activeServerName: 'Test server',
      location: state.uri.path,
      deferBack: deferBack,
      child: child,
    ),
    routes: [
      GoRoute(
        path: '/home',
        pageBuilder: (_, state) => NoTransitionPage<void>(
          key: state.pageKey,
          child: _Page(state.uri.path),
        ),
      ),
      GoRoute(
        path: '/collection',
        pageBuilder: (_, state) => _material(state),
        routes: [
          GoRoute(
            path: ':id',
            pageBuilder: (_, state) => _material(state),
          ),
        ],
      ),
      GoRoute(path: '/games', pageBuilder: (_, state) => _material(state)),
      GoRoute(path: '/events', pageBuilder: (_, state) => _material(state)),
      GoRoute(
        path: '/settings',
        pageBuilder: (_, state) => _material(state),
      ),
      GoRoute(
        path: '/feedback',
        pageBuilder: (_, state) => _material(state),
      ),
    ],
  );
  final router = GoRouter(
    initialLocation: at,
    routes: [
      if (inOuterShell)
        ShellRoute(builder: (_, _, child) => child, routes: [shell])
      else
        shell,
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      theme: platform == null ? theme : theme.copyWith(platform: platform),
      localizationsDelegates: ShellLocalizations.localizationsDelegates,
      supportedLocales: ShellLocalizations.supportedLocales,
      builder: (context, child) {
        // Read from the view, so a resize or a cutout reaches it.
        Widget app = MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Directionality(textDirection: textDirection, child: child!),
        );
        if (underRegion) app = underSelectionRegion(context, app);
        if (boundary != null) app = RepaintBoundary(key: boundary, child: app);
        return app;
      },
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(tester, router, runs);
}

Finder get _bar => find.byKey(NavigationShell.barKey);
Finder get _rail => find.byKey(NavigationShell.railKey);
Finder _destination(String id) =>
    find.byKey(NavigationShell.destinationKey(id));
Finder _entry(String id) => find.byKey(MenuDrawer.entryKey(id));

/// The focus node of the bar's or the rail's destination [id]: Flutter's,
/// inside the destination, below the bar's key and above the rail's.
FocusNode _destinationNode(WidgetTester tester, String id) {
  final element = tester.element(_destination(id));
  final byContext = <BuildContext?, FocusNode>{
    for (final node in FocusManager.instance.rootScope.descendants)
      if (node is! FocusScopeNode && node.canRequestFocus) node.context: node,
  };
  FocusNode? found;
  void visit(Element e) {
    found ??= byContext[e];
    if (found == null) e.visitChildren(visit);
  }

  visit(element);
  return found ?? Focus.of(element);
}

bool _inside(FocusNode? node, Finder chrome) =>
    node?.context != null &&
    find
        .ancestor(
          of: find.byElementPredicate((e) => e == node!.context),
          matching: chrome,
        )
        .evaluate()
        .isNotEmpty;

void main() {
  group('the form follows the window class (#414)', () {
    testWidgets("compact shows the bar with the location's destination "
        'selected', (tester) async {
      await _pump(tester, at: '/collection/1');

      expect(_bar, findsOneWidget);
      expect(_rail, findsNothing);
      expect(tester.widget<NavigationBar>(_bar).selectedIndex, 1);
      for (final destination in _destinations) {
        expect(
          find.descendant(of: _bar, matching: _destination(destination.id)),
          findsOneWidget,
        );
      }
    });

    testWidgets('medium shows a rail with selected labels and the menu at '
        'its top', (tester) async {
      await _pump(tester, size: const Size(700, 800));

      expect(_bar, findsNothing);
      final rail = tester.widget<NavigationRail>(_rail);
      expect(rail.labelType, NavigationRailLabelType.selected);
      expect(rail.selectedIndex, 0);
      // The page's own control, so the two read the same.
      expect(rail.leading, isA<BgeMenuButton>());
      final menu = tester.widget<IconButton>(
        find.descendant(of: _rail, matching: find.byType(IconButton)),
      );
      expect((menu.icon as Icon).icon, Icons.menu);
      expect(menu.tooltip, 'Open navigation menu');
      // The rail carries the menu, so the page shows none, and no back
      // arrow either: it is the first route.
      expect(find.byKey(BgePage.menuButtonKey), findsNothing);
      expect(find.byType(BackButton), findsNothing);

      await tester.tap(
        find.descendant(of: _rail, matching: find.byIcon(Icons.menu)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
    });

    testWidgets('expanded shows every label', (tester) async {
      await _pump(tester, size: const Size(1000, 800));

      expect(
        tester.widget<NavigationRail>(_rail).labelType,
        NavigationRailLabelType.all,
      );
    });

    testWidgets('compact leaves the menu button to the page', (tester) async {
      final shell = await _pump(tester);

      await tester.tap(find.byKey(BgePage.menuButtonKey));
      await tester.pumpAndSettle();

      expect(shell.scaffold.isDrawerOpen, isTrue);
    });

    testWidgets('the drawer lists no destinations while a bar or rail shows '
        'them', (tester) async {
      for (final size in [const Size(400, 800), const Size(700, 800)]) {
        final shell = await _pump(tester, size: size, at: '/games');
        await shell.openMenu();

        expect(shell.drawer.destinations, isEmpty, reason: '$size');
        expect(_entry('settings'), findsOneWidget);
      }
    });

    testWidgets('no bar or rail on a screen the menu opens, and the drawer '
        'lists the destinations there', (tester) async {
      for (final size in [const Size(400, 800), const Size(700, 800)]) {
        final shell = await _pump(tester, size: size);
        await shell.openMenu();
        await tester.tap(_entry('settings'));
        await tester.pumpAndSettle();
        expect(shell.location, '/settings');

        expect(_bar, findsNothing, reason: '$size');
        expect(_rail, findsNothing, reason: '$size');
        await shell.openMenu();
        expect(shell.drawer.destinations, _destinations);
        expect(shell.drawer.selectedId, isNull);
        for (final destination in _destinations) {
          expect(_entry(destination.id), findsOneWidget);
        }
      }
    });

    testWidgets('one destination: no bar or rail, the drawer lists it', (
      tester,
    ) async {
      for (final size in [const Size(400, 800), const Size(700, 800)]) {
        final shell = await _pump(tester, size: size, destinations: [_home]);

        expect(_bar, findsNothing);
        expect(_rail, findsNothing);
        // No rail to carry the menu, so the page does.
        await tester.tap(find.byKey(BgePage.menuButtonKey));
        await tester.pumpAndSettle();
        expect(shell.drawer.destinations, [_home]);
        expect(shell.drawer.selectedId, 'home');
      }
    });
  });

  group('picking a destination (#414)', () {
    testWidgets('picking a destination goes there', (tester) async {
      final shell = await _pump(tester);

      await tester.tap(_destination('games'));
      await tester.pumpAndSettle();

      expect(shell.location, '/games');
      expect(tester.widget<NavigationBar>(_bar).selectedIndex, 2);
      // A go, not a push: nothing beneath it to go back to.
      expect(
        GoRouter.of(tester.element(find.byKey(_Page.bodyKey('/games'))))
            .canPop(),
        isFalse,
      );
    });

    testWidgets('picking a destination on the rail goes there', (
      tester,
    ) async {
      final shell = await _pump(tester, size: const Size(700, 800));

      await tester.tap(_destination('games'));
      await tester.pumpAndSettle();

      expect(shell.location, '/games');
      expect(tester.widget<NavigationRail>(_rail).selectedIndex, 2);
    });

    testWidgets('picking the current destination does nothing', (
      tester,
    ) async {
      final shell = await _pump(tester, at: '/collection');
      final page = shell.page('/collection');
      var navigations = 0;
      shell.router.routeInformationProvider.addListener(() => navigations++);

      await tester.tap(_destination('collection'));
      await tester.pumpAndSettle();

      expect(navigations, 0);
      expect(shell.location, '/collection');
      expect(shell.page('/collection'), same(page));
    });

    testWidgets('picking a destination from one of its pages goes to the '
        "destination's own screen", (tester) async {
      final shell = await _pump(tester, at: '/collection');
      await shell.push('/collection/1');

      await tester.tap(_destination('collection'));
      await tester.pumpAndSettle();

      expect(shell.location, '/collection');
    });

    // Home's See all and Collection's Browse push Games over the page they
    // are on. Picking Games there is still a go: it replaces the stack, and
    // the pushed copy's query goes with it.
    testWidgets('picking a destination from a pushed copy of its own screen '
        'replaces the stack', (tester) async {
      final shell = await _pump(tester);
      await shell.push('/games?sort=newest');
      expect(shell.router.canPop(), isTrue);
      expect(find.byType(BackButton), findsOneWidget);

      await tester.tap(_destination('games'));
      await tester.pumpAndSettle();

      expect(shell.router.state.uri.toString(), '/games');
      expect(shell.router.canPop(), isFalse);
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('a destination picked in the drawer goes there once the '
        'drawer has closed', (tester) async {
      final shell = await _pump(tester, at: '/settings');
      await shell.openMenu();

      await tester.tap(_entry('games'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(shell.location, '/settings');
      expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);

      await tester.pumpAndSettle();
      expect(shell.location, '/games');
      expect(find.byKey(MenuDrawer.drawerKey), findsNothing);
    });
  });

  group('a menu entry runs after the drawer has closed (#643)', () {
    testWidgets('a menu entry runs only after the drawer has closed', (
      tester,
    ) async {
      final shell = await _pump(tester);
      await shell.openMenu();

      await tester.tap(_entry('settings'));
      expect(shell.runs, isEmpty);
      expect(shell.scaffold.isDrawerOpen, isFalse);
      // Mid-close: the drawer is still on screen, sliding out.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
      expect(shell.runs, isEmpty);
      expect(shell.location, '/home');

      await tester.pumpAndSettle();
      expect(shell.runs, ['settings']);
      expect(shell.location, '/settings');
    });

    // A tap on the drawer as it closes stops the close, and Flutter opens
    // the drawer again from past halfway: early and late taps differ.
    for (final gap in [16, 50, 150, 250]) {
      testWidgets('picking twice during the close runs once (${gap}ms '
          'apart)', (tester) async {
        final shell = await _pump(tester);
        await shell.openMenu();

        await tester.tap(_entry('settings'));
        await tester.pump(Duration(milliseconds: gap));
        await tester.tap(_entry('settings'), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.tap(_entry('households'), warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(shell.runs, ['settings']);
        expect(shell.location, '/settings');
        expect(find.byKey(MenuDrawer.drawerKey), findsNothing);
      });
    }

    testWidgets('an entry with a location pushes its screen once the drawer '
        'has closed', (tester) async {
      final shell = await _pump(tester);
      await shell.openMenu();

      await tester.tap(_entry('feedback'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(shell.location, '/home');

      await tester.pumpAndSettle();
      expect(shell.location, '/feedback');
      expect(shell.router.canPop(), isTrue);
    });

    // The menu is on every page now, not home's alone, so the screen an
    // entry opens can be the one on top: a second copy would only add a
    // step to Back.
    testWidgets('picking the entry for the screen on top does nothing', (
      tester,
    ) async {
      final shell = await _pump(tester, platform: TargetPlatform.android);
      await shell.push('/feedback');
      final page = shell.page('/feedback');
      var navigations = 0;
      shell.router.routeInformationProvider.addListener(() => navigations++);
      await shell.openMenu();

      await tester.tap(_entry('feedback'));
      await tester.pumpAndSettle();

      expect(navigations, 0);
      expect(shell.location, '/feedback');
      expect(shell.page('/feedback'), same(page));
      expect(find.byKey(MenuDrawer.drawerKey), findsNothing);
      expect(await shell.back(), isTrue);
      expect(shell.location, '/home');
    });

    testWidgets('sign out runs at once', (tester) async {
      final shell = await _pump(tester);
      await shell.openMenu();

      await tester.tap(_entry('sign_out'));

      expect(shell.runs, ['sign_out']);
      expect(shell.scaffold.isDrawerOpen, isFalse);
      await tester.pumpAndSettle();
      expect(shell.runs, ['sign_out']);
    });

    testWidgets('once a pick has run, the next one is taken', (
      tester,
    ) async {
      final shell = await _pump(tester);
      for (final id in ['households', 'sign_out', 'households']) {
        await shell.openMenu();
        await tester.tap(_entry(id));
        await tester.pumpAndSettle();
      }

      expect(shell.runs, ['households', 'sign_out', 'households']);
    });
  });

  group('System Back (#414)', () {
    testWidgets('Back closes an open drawer before popping a page', (
      tester,
    ) async {
      final shell = await _pump(tester, at: '/collection');
      await shell.push('/collection/1');
      await shell.openMenu();

      expect(await shell.back(), isTrue);
      expect(shell.scaffold.isDrawerOpen, isFalse);
      expect(shell.location, '/collection/1');

      // With the drawer closed, Back pops the page.
      expect(await shell.back(), isTrue);
      expect(shell.location, '/collection');
    });

    // The pick has closed the drawer already, so Back while it closes reads
    // as "never mind": the pick is dropped, and Back does nothing else.
    testWidgets('Back while a pick waits for the drawer to go cancels the '
        'pick', (tester) async {
      final shell = await _pump(tester, at: '/collection');
      await shell.push('/collection/1');
      await shell.openMenu();

      await tester.tap(_entry('settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);

      expect(await shell.back(), isTrue);
      expect(find.byKey(MenuDrawer.drawerKey), findsNothing);
      expect(shell.location, '/collection/1');
      expect(shell.runs, isEmpty);

      // The next pick is taken.
      await shell.openMenu();
      await tester.tap(_entry('settings'));
      await tester.pumpAndSettle();
      expect(shell.runs, ['settings']);
      expect(shell.location, '/settings');
    });

    testWidgets("Back on a destination's own screen goes home", (
      tester,
    ) async {
      final shell = await _pump(tester);
      await tester.tap(_destination('games'));
      await tester.pumpAndSettle();

      expect(await shell.back(), isTrue);
      expect(shell.location, '/home');
    });

    testWidgets('Back on Home falls through', (tester) async {
      final shell = await _pump(tester);

      expect(await shell.back(), isFalse);
      expect(shell.location, '/home');
    });

    testWidgets('Back with a dialog over a destination closes the dialog '
        'first', (tester) async {
      final shell = await _pump(tester, at: '/games');
      unawaited(
        showDialog<void>(
          context: tester.element(find.byKey(_Page.bodyKey('/games'))),
          builder: (_) => const AlertDialog(content: Text('A dialog')),
        ),
      );
      await tester.pumpAndSettle();

      expect(await shell.back(), isTrue);
      expect(find.text('A dialog'), findsNothing);
      expect(shell.location, '/games');

      expect(await shell.back(), isTrue);
      expect(shell.location, '/home');
    });

    // Inside another shell, as the app's auth shell holds it, the shell's
    // own route stays current on its navigator under a root dialog.
    for (final inOuterShell in [false, true]) {
      testWidgets(
        'Back with a dialog over the open drawer closes the dialog, '
        'and leaves the drawer${inOuterShell ? ' (in an outer shell)' : ''}',
        (
          tester,
        ) async {
          final shell = await _pump(
            tester,
            at: '/collection',
            inOuterShell: inOuterShell,
          );
          await shell.openMenu();
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(MenuDrawer)),
              builder: (_) => const AlertDialog(content: Text('A dialog')),
            ),
          );
          await tester.pumpAndSettle();

          expect(await shell.back(), isTrue);
          expect(find.text('A dialog'), findsNothing);
          expect(shell.scaffold.isDrawerOpen, isTrue);

          expect(await shell.back(), isTrue);
          expect(shell.scaffold.isDrawerOpen, isFalse);
          expect(shell.location, '/collection');
        },
      );
    }

    // Something over the app that takes Back through a handler of its own,
    // such as the recovery notice (#428), may have come up before the shell.
    testWidgets('Back passes while the app defers it', (tester) async {
      var deferred = true;
      final shell = await _pump(
        tester,
        at: '/games',
        deferBack: () => deferred,
      );

      expect(await shell.back(), isFalse);
      expect(shell.location, '/games');

      deferred = false;
      expect(await shell.back(), isTrue);
      expect(shell.location, '/home');
    });
  });

  group('the selection region (#625)', () {
    // A drag the length of the entry: the app-wide region's drag recognizer,
    // an ancestor no wrap reaches, takes the gesture from ~2.5px on and the
    // tap is cancelled, as on every button under that region (#322). What
    // the wrap holds is that the drag selects nothing.
    testWidgets('a press-drag across a drawer entry selects nothing, and '
        'runs nothing', (tester) async {
      final copies = captureClipboardCopies();
      // A screen the menu opens: the drawer lists destinations too.
      final shell = await _pump(
        tester,
        size: const Size(1280, 800),
        at: '/settings',
        underRegion: true,
      );
      await tester.tap(find.byKey(BgePage.menuButtonKey));
      await tester.pumpAndSettle();

      for (final id in ['settings', 'games']) {
        final entry = tester.getRect(_entry(id));
        await mouseDrag(
          tester,
          entry.centerLeft + const Offset(4, 0),
          entry.centerRight - const Offset(4, 0),
        );
        await sendCopyShortcut(tester);
      }

      expect(copies.join(), isEmpty);
      expect(shell.scaffold.isDrawerOpen, isTrue);
      expect(shell.runs, isEmpty);
      expect(shell.location, '/settings');
    });

    // A hand on a mouse moves a little as it clicks.
    testWidgets('a press that moves 2px on a drawer entry runs it', (
      tester,
    ) async {
      final copies = captureClipboardCopies();
      final shell = await _pump(
        tester,
        size: const Size(1280, 800),
        at: '/settings',
        underRegion: true,
      );

      for (final id in ['households', 'games']) {
        await tester.tap(find.byKey(BgePage.menuButtonKey));
        await tester.pumpAndSettle();
        final entry = tester.getCenter(_entry(id));
        await mouseDrag(tester, entry, entry + const Offset(2, 0), steps: 2);
        await tester.pumpAndSettle();
        await sendCopyShortcut(tester);
      }

      expect(copies.join(), isEmpty);
      expect(shell.runs, ['households']);
      expect(shell.location, '/games');
    });

    testWidgets('a press-drag across the bar or the rail starts no '
        'selection', (tester) async {
      for (final size in [const Size(400, 800), const Size(1280, 800)]) {
        final copies = captureClipboardCopies();
        final shell = await _pump(tester, size: size, underRegion: true);

        final label = tester.getRect(
          find.descendant(
            of: size.width < 600 ? _bar : _rail,
            matching: find.text('Home'),
          ),
        );
        await mouseDrag(
          tester,
          label.centerLeft - const Offset(8, 0),
          label.centerRight + const Offset(8, 0),
        );
        await sendCopyShortcut(tester);

        expect(copies.join(), isEmpty, reason: '$size');
        expect(shell.location, '/home');
      }
    });
  });

  group('the pages beneath the chrome (#414)', () {
    testWidgets('a page keeps its state across a resize from compact to '
        'medium and back', (tester) async {
      final shell = await _pump(tester, at: '/collection');
      final page = shell.page('/collection');
      final messenger = tester.state(find.byType(ScaffoldMessenger).last);

      await shell.resize(const Size(700, 800));
      expect(_rail, findsOneWidget);
      expect(shell.page('/collection'), same(page));
      expect(
        tester.state(find.byType(ScaffoldMessenger).last),
        same(messenger),
      );

      await shell.resize(const Size(1000, 800));
      await shell.resize(const Size(400, 800));
      expect(_bar, findsOneWidget);
      expect(shell.page('/collection'), same(page));
    });

    testWidgets('the chrome going on a screen the menu opens keeps the pages '
        'beneath', (tester) async {
      final shell = await _pump(tester, size: const Size(700, 800));
      final home = shell.page('/home');

      await shell.push('/settings');
      expect(_rail, findsNothing);
      expect(shell.page('/home'), same(home));

      expect(await shell.back(), isTrue);
      expect(_rail, findsOneWidget);
      expect(shell.page('/home'), same(home));
    });

    testWidgets("a page's SnackBar shows in the page, above the bar, and "
        'moves its FAB', (tester) async {
      await _pump(tester);
      final fab = find.byKey(_Page.fabKey('/home'));
      final fabBefore = tester.getRect(fab);
      final page = tester.element(find.byKey(_Page.bodyKey('/home')));

      ScaffoldMessenger.of(page).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
      await tester.pumpAndSettle();

      final snackBar = tester.getRect(find.byType(SnackBar));
      final fabAfter = tester.getRect(fab);
      // The nearest Scaffold above each: the page's, not the shell's.
      Element scaffoldOf(Finder finder) => tester.element(
        find.ancestor(of: finder, matching: find.byType(Scaffold)).first,
      );
      expect(
        scaffoldOf(find.text('Saved')),
        same(scaffoldOf(find.byKey(_Page.bodyKey('/home')))),
      );
      expect(
        scaffoldOf(find.text('Saved')),
        isNot(same(tester.element(find.byType(Scaffold).first))),
      );
      expect(fabAfter.top, lessThan(fabBefore.top));
      expect(snackBar.overlaps(fabAfter), isFalse);
      expect(snackBar.bottom, lessThanOrEqualTo(tester.getRect(_bar).top));
    });
  });

  group('the platform and the window (#414)', () {
    /// Swipes from the window's left edge to its middle, as a thumb does.
    Future<void> edgeSwipe(WidgetTester tester) async {
      final swipe = await tester.startGesture(const Offset(5, 400));
      for (var i = 0; i < 30; i++) {
        await swipe.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await tester.pumpAndSettle();
    }

    testWidgets('on iOS an edge swipe on a pushed page goes back, and the '
        'drawer stays shut', (tester) async {
      final shell = await _pump(
        tester,
        at: '/collection',
        platform: TargetPlatform.iOS,
      );
      await shell.push('/collection/1');

      await edgeSwipe(tester);

      expect(shell.location, '/collection');
      expect(shell.scaffold.isDrawerOpen, isFalse);
    });

    testWidgets('on Android an edge drag on a pushed page opens the drawer', (
      tester,
    ) async {
      final shell = await _pump(
        tester,
        at: '/collection',
        platform: TargetPlatform.android,
      );
      await shell.push('/collection/1');

      await edgeSwipe(tester);

      expect(shell.scaffold.isDrawerOpen, isTrue);
      expect(shell.location, '/collection/1');
    });

    for (final direction in TextDirection.values) {
      testWidgets('a rail beside a cutout insets the pages once '
          '(${direction.name})', (tester) async {
        final ltr = direction == TextDirection.ltr;
        final shell = await _pump(
          tester,
          size: const Size(852, 393),
          at: '/collection',
          textDirection: direction,
        );
        // From the rail's inner edge to the page title's start.
        double gap() {
          final rail = tester.getRect(_rail);
          final title = tester.getRect(find.text('Page /collection'));
          return ltr ? title.left - rail.right : rail.left - title.right;
        }

        EdgeInsets pagePadding(String name) => MediaQuery.paddingOf(
          tester.element(
            find
                .ancestor(
                  of: find.byKey(_Page.bodyKey(name)),
                  matching: find.byType(Scaffold),
                )
                .first,
          ),
        );

        final railWidth = tester.getRect(_rail).width;
        final clear = gap();

        // A landscape iPhone's cutout, on the rail's side.
        tester.view.padding = FakeViewPadding(
          left: ltr ? 59 : 0,
          right: ltr ? 0 : 59,
        );
        await tester.pumpAndSettle();

        // The rail takes the cutout, and the page starts where it did.
        expect(tester.getRect(_rail).width, railWidth + 59);
        expect(gap(), clear);
        expect(
          ltr
              ? pagePadding('/collection').left
              : pagePadding('/collection').right,
          0,
        );

        // Without a rail the pages keep the inset.
        await shell.push('/settings');
        expect(_rail, findsNothing);
        expect(
          ltr ? pagePadding('/settings').left : pagePadding('/settings').right,
          59,
        );
      });
    }
  });

  group('no overflow at small windows or large text (#414)', () {
    final cases = <(String, Size, double)>[
      ('the rail in a landscape phone', const Size(700, 360), 1),
      ('the rail in a landscape phone at 200% text', const Size(700, 360), 2),
      (
        'every rail label in a short window at 200% text',
        const Size(1000, 360),
        2,
      ),
      ('the rail at 200% text', const Size(700, 800), 2),
      ('the bar at 320dp and 200% text', const Size(320, 640), 2),
    ];
    for (final (name, size, scale) in cases) {
      testWidgets(name, (tester) async {
        await _pump(tester, size: size, textScale: scale, at: '/collection');

        expect(tester.takeException(), isNull);
        expect(size.width < 600 ? _bar : _rail, findsOneWidget);
      });
    }
  });

  group('focus and screen readers (#414)', () {
    testWidgets('a resize from compact to medium keeps the selected '
        'destination and focus', (tester) async {
      final shell = await _pump(tester, at: '/collection');
      _destinationNode(tester, 'collection').requestFocus();
      await tester.pump();
      expect(_inside(FocusManager.instance.primaryFocus, _bar), isTrue);

      await shell.resize(const Size(700, 800));

      expect(tester.widget<NavigationRail>(_rail).selectedIndex, 1);
      expect(
        FocusManager.instance.primaryFocus,
        _destinationNode(tester, 'collection'),
      );
      expect(_inside(FocusManager.instance.primaryFocus, _rail), isTrue);

      await shell.resize(const Size(400, 800));

      expect(tester.widget<NavigationBar>(_bar).selectedIndex, 1);
      expect(
        FocusManager.instance.primaryFocus,
        _destinationNode(tester, 'collection'),
      );
      expect(_inside(FocusManager.instance.primaryFocus, _bar), isTrue);
    });

    testWidgets('a resize from medium to expanded keeps focus on the rail '
        'destination', (tester) async {
      final shell = await _pump(
        tester,
        at: '/collection',
        size: const Size(700, 800),
      );
      final node = _destinationNode(tester, 'collection')..requestFocus();
      await tester.pump();

      await shell.resize(const Size(1000, 800));

      expect(
        tester.widget<NavigationRail>(_rail).labelType,
        NavigationRailLabelType.all,
      );
      expect(FocusManager.instance.primaryFocus, same(node));

      await shell.resize(const Size(700, 800));

      expect(FocusManager.instance.primaryFocus, same(node));
    });

    testWidgets('a resize leaves focus off the chrome alone', (tester) async {
      final shell = await _pump(tester, at: '/collection');
      final fab = Focus.of(
        tester.element(find.byIcon(Icons.add)),
      )..requestFocus();
      await tester.pump();

      await shell.resize(const Size(700, 800));

      expect(FocusManager.instance.primaryFocus, fab);
    });

    testWidgets('the drawer stays open across a resize, with focus on its '
        'entry', (tester) async {
      final shell = await _pump(tester);
      await shell.openMenu();
      Focus.of(
        tester.element(
          find.descendant(
            of: _entry('settings'),
            matching: find.text('Settings'),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      bool onSettings() =>
          _inside(FocusManager.instance.primaryFocus, _entry('settings'));
      expect(onSettings(), isTrue);

      await shell.resize(const Size(700, 800));
      expect(shell.scaffold.isDrawerOpen, isTrue);
      expect(find.byKey(MenuDrawer.drawerKey), findsOneWidget);
      expect(onSettings(), isTrue);

      await shell.resize(const Size(400, 800));
      expect(shell.scaffold.isDrawerOpen, isTrue);
      expect(onSettings(), isTrue);
    });

    for (final size in [const Size(400, 800), const Size(700, 800)]) {
      testWidgets('Tab reaches every destination, read by its label '
          '(${size.width.toInt()} wide)', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pump(tester, size: size);

        final names = await tabOrder(tester);

        for (final destination in _destinations) {
          expect(names, contains(startsWith(destination.label)));
        }
        if (size.width >= 600) {
          expect(names, contains('Open navigation menu'));
        }
        semantics.dispose();
      });
    }
  });

  // The chrome is met in visual order: a rail's menu button, then Home down
  // to Events; a bar's Home to Events left to right (#414).
  group('Tab walks the chrome in the order it is drawn (#414)', () {
    Future<List<String>> chromeStops(
      WidgetTester tester,
      Size size, {
      bool reverse = false,
    }) async {
      await _pump(tester, size: size);
      final stops = await tabStops(tester, reverse: reverse);
      // The bar's or the rail's own stops. The page's, its Add button and
      // at compact its menu button, are left out by where they are.
      final chrome = size.width >= 600 ? _rail : _bar;
      return [
        for (final stop in stops)
          if (_inside(stop.node, chrome)) stop.name,
      ];
    }

    testWidgets('Tab walks the rail in order: menu, Home, Collection, Games, '
        'Events', (tester) async {
      final semantics = tester.ensureSemantics();
      final stops = await chromeStops(tester, const Size(700, 800));
      expect(stops, [
        'Open navigation menu',
        'Home\nTab 1 of 4',
        'Collection\nTab 2 of 4',
        'Games\nTab 3 of 4',
        'Events\nTab 4 of 4',
      ]);
      semantics.dispose();
    });

    testWidgets('Shift+Tab walks the rail back', (tester) async {
      final semantics = tester.ensureSemantics();
      final stops = await chromeStops(
        tester,
        const Size(700, 800),
        reverse: true,
      );
      expect(stops, [
        'Events\nTab 4 of 4',
        'Games\nTab 3 of 4',
        'Collection\nTab 2 of 4',
        'Home\nTab 1 of 4',
        'Open navigation menu',
      ]);
      semantics.dispose();
    });

    testWidgets('Tab walks the bar in order: Home, Collection, Games, '
        'Events', (tester) async {
      final semantics = tester.ensureSemantics();
      final stops = await chromeStops(tester, const Size(400, 800));
      expect(stops, [
        'Home\nTab 1 of 4',
        'Collection\nTab 2 of 4',
        'Games\nTab 3 of 4',
        'Events\nTab 4 of 4',
      ]);
      semantics.dispose();
    });

    testWidgets('Shift+Tab walks the bar back', (tester) async {
      final semantics = tester.ensureSemantics();
      final stops = await chromeStops(
        tester,
        const Size(400, 800),
        reverse: true,
      );
      expect(stops, [
        'Events\nTab 4 of 4',
        'Games\nTab 3 of 4',
        'Collection\nTab 2 of 4',
        'Home\nTab 1 of 4',
      ]);
      semantics.dispose();
    });
  });

  // #644: a rail shows focus as a fill alone, and its fill is the shell's
  // to set, around the rail only. The bar's is the theme's, tested in
  // ui_tokens.
  group("a rail's focused destination differs from rest by 3:1 (#644)", () {
    final themes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };

    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets(name, (tester) async {
        // A focus fill shows in keyboard mode only.
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(
          () => FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic,
        );
        final boundary = GlobalKey();
        await _pump(
          tester,
          size: const Size(700, 800),
          themeData: build(),
          boundary: boundary,
        );

        Future<Color Function(Offset)> capture() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final (width, bytes) = (await tester.runAsync(() async {
            final image = await render.toImage();
            final bytes = (await image.toByteData())!;
            final width = image.width;
            image.dispose();
            return (width, bytes);
          }))!;
          Color colourAt(Offset point) {
            final at = (point.dy.floor() * width + point.dx.floor()) * 4;
            return Color.fromARGB(
              bytes.getUint8(at + 3),
              bytes.getUint8(at),
              bytes.getUint8(at + 1),
              bytes.getUint8(at + 2),
            );
          }

          return colourAt;
        }

        // The second destination: the first is selected.
        final icon = tester.getRect(_destination('collection'));
        final area = icon.inflate(8);
        final atRest = await capture();

        _destinationNode(tester, 'collection').requestFocus();
        await tester.pumpAndSettle();
        final focused = await capture();

        var strongest = 1.0;
        for (var y = area.top.ceil(); y < area.bottom.floor(); y++) {
          for (var x = area.left.ceil(); x < area.right.floor(); x++) {
            final point = Offset(x + 0.5, y + 0.5);
            final ratio = Wcag.contrastRatio(atRest(point), focused(point));
            if (ratio > strongest) strongest = ratio;
          }
        }
        expect(strongest, greaterThanOrEqualTo(3.0), reason: 'the fill');

        // The icon against the fill beside it.
        final fill = focused(Offset(icon.left - 4, icon.center.dy));
        var iconRatio = 1.0;
        for (var y = icon.top.ceil(); y < icon.bottom.floor(); y++) {
          for (var x = icon.left.ceil(); x < icon.right.floor(); x++) {
            final ratio = Wcag.contrastRatio(
              focused(Offset(x + 0.5, y + 0.5)),
              fill,
            );
            if (ratio > iconRatio) iconRatio = ratio;
          }
        }
        expect(iconRatio, greaterThanOrEqualTo(3.0), reason: 'the icon');
      });
    }
  });
}
