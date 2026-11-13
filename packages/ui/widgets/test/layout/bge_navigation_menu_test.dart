import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

const _pushKey = Key('push');

/// A page whose Push button pushes [next], or a plain page titled Pushed.
Widget _page(
  String title, {
  Widget? leading,
  bool implyLeading = true,
  Widget Function()? next,
}) => BgePage(
  title: Text(title),
  leading: leading,
  automaticallyImplyLeading: implyLeading,
  child: Builder(
    builder: (context) => TextButton(
      key: _pushKey,
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => next?.call() ?? _page('Pushed'),
        ),
      ),
      child: const Text('Push'),
    ),
  ),
);

Widget _host({
  required Widget home,
  VoidCallback? onOpen,
  bool offersPageButton = true,
  bool browserOwnsBack = false,
  bool withMenu = true,
}) => MaterialApp(
  home: home,
  builder: (context, child) => withMenu
      ? BgeNavigationMenu(
          onOpen: onOpen ?? () {},
          offersPageButton: offersPageButton,
          browserOwnsBack: browserOwnsBack,
          child: child!,
        )
      : child!,
);

/// Pushes the page home's Push button opens.
Future<void> _push(WidgetTester tester) async {
  await tester.tap(find.byKey(_pushKey));
  await tester.pumpAndSettle();
}

Finder get _menuButton => find.byKey(BgePage.menuButtonKey);

/// The menu's fields in state, so a change rebuilds the menu and leaves the
/// navigator beneath it alone, as a shell's build does: the pages' navigator
/// is the same widget across it.
class _MenuHost extends StatefulWidget {
  const _MenuHost({required this.child, super.key});

  final Widget child;

  @override
  State<_MenuHost> createState() => _MenuHostState();
}

class _MenuHostState extends State<_MenuHost> {
  VoidCallback _onOpen = () {};
  bool _offersPageButton = true;
  bool _browserOwnsBack = false;
  bool _present = true;

  void change({
    VoidCallback? onOpen,
    bool? offersPageButton,
    bool? browserOwnsBack,
    bool? present,
  }) => setState(() {
    _onOpen = onOpen ?? _onOpen;
    _offersPageButton = offersPageButton ?? _offersPageButton;
    _browserOwnsBack = browserOwnsBack ?? _browserOwnsBack;
    _present = present ?? _present;
  });

  @override
  Widget build(BuildContext context) => _present
      ? BgeNavigationMenu(
          onOpen: _onOpen,
          offersPageButton: _offersPageButton,
          browserOwnsBack: _browserOwnsBack,
          child: widget.child,
        )
      : widget.child;
}

Widget _hostWithState(GlobalKey<_MenuHostState> host) => MaterialApp(
  home: _page('Home'),
  builder: (context, child) => _MenuHost(key: host, child: child!),
);

void main() {
  group('BgeNavigationMenu and BgePage', () {
    testWidgets('the first route under a menu shows the menu button, and it '
        'calls onOpen', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(home: _page('Home'), onOpen: () => opened++),
      );

      expect(_menuButton, findsOneWidget);
      expect(find.byIcon(Icons.menu), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      await tester.tap(_menuButton);
      expect(opened, 1);
    });

    testWidgets('a pushed route under a menu keeps its back arrow', (
      tester,
    ) async {
      await tester.pumpWidget(_host(home: _page('Home')));
      await tester.tap(find.byKey(_pushKey));
      await tester.pumpAndSettle();

      expect(find.text('Pushed'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(_menuButton, findsNothing);
    });

    testWidgets('with offersPageButton false, the first route shows neither', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(home: _page('Home'), offersPageButton: false),
      );

      expect(_menuButton, findsNothing);
      expect(find.byType(BackButton), findsNothing);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('a title-less first route under a menu has no app bar, so no '
        'menu button', (tester) async {
      // The menu button rides in the app bar, and a page with no title has
      // none. Such a page reaches the menu through the rail, or the drawer's
      // edge drag.
      await tester.pumpWidget(
        _host(home: const BgePage(child: Text('Untitled'))),
      );

      expect(find.text('Untitled'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(_menuButton, findsNothing);
    });

    testWidgets('with no menu above, nothing changes', (tester) async {
      await tester.pumpWidget(_host(home: _page('Home'), withMenu: false));
      expect(_menuButton, findsNothing);
      expect(find.byType(BackButton), findsNothing);

      await tester.tap(find.byKey(_pushKey));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
    });

    testWidgets('an explicit leading wins over the menu', (tester) async {
      await tester.pumpWidget(
        _host(
          home: _page('Home', leading: const Icon(Icons.star)),
        ),
      );

      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(_menuButton, findsNothing);
    });

    testWidgets('automaticallyImplyLeading false wins over the menu', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(home: _page('Home', implyLeading: false)),
      );

      expect(_menuButton, findsNothing);
    });

    testWidgets('the menu button is named by openAppDrawerTooltip', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(home: _page('Home')));

      expect(tester.widget(_menuButton), isA<BgeMenuButton>());
      expect(
        tester.getSemantics(_menuButton).tooltip,
        const DefaultMaterialLocalizations().openAppDrawerTooltip,
      );
      handle.dispose();
    });

    // A change that rebuilds the menu and not the pages beneath it, as a
    // shell's does: only the menu's notice reaches the page.
    testWidgets('a change to offersPageButton rebuilds the page', (
      tester,
    ) async {
      final host = GlobalKey<_MenuHostState>();
      await tester.pumpWidget(_hostWithState(host));
      expect(_menuButton, findsOneWidget);

      host.currentState!.change(offersPageButton: false);
      await tester.pump();
      expect(_menuButton, findsNothing);
      expect(find.byType(BackButton), findsNothing);

      host.currentState!.change(offersPageButton: true);
      await tester.pump();
      expect(_menuButton, findsOneWidget);
    });

    testWidgets('the menu going from above the page takes its button, and '
        'coming back brings it back', (tester) async {
      final host = GlobalKey<_MenuHostState>();
      await tester.pumpWidget(_hostWithState(host));
      expect(_menuButton, findsOneWidget);

      host.currentState!.change(present: false);
      await tester.pump();
      expect(_menuButton, findsNothing);

      host.currentState!.change(present: true);
      await tester.pump();
      expect(_menuButton, findsOneWidget);
    });

    testWidgets('a change to onOpen reaches the page button', (tester) async {
      final host = GlobalKey<_MenuHostState>();
      final opened = <String>[];
      await tester.pumpWidget(_hostWithState(host));
      host.currentState!.change(onOpen: () => opened.add('first'));
      await tester.pump();
      host.currentState!.change(onOpen: () => opened.add('second'));
      await tester.pump();

      await tester.tap(_menuButton);
      expect(opened, ['second']);
    });

    testWidgets('without browserOwnsBack, a pushed top-level page keeps its '
        'back arrow', (tester) async {
      await tester.pumpWidget(
        _host(
          home: _page(
            'Home',
            next: () => BgeTopLevelRoute(child: _page('Section')),
          ),
        ),
      );
      await _push(tester);

      expect(find.text('Section'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(_menuButton, findsNothing);
    });
  });

  // #611: on the web the browser's own Back is the way back, so the in-app
  // arrow would repeat it.
  group('browser owns back (#611)', () {
    testWidgets('the first route shows the menu', (tester) async {
      await tester.pumpWidget(
        _host(home: _page('Home'), browserOwnsBack: true),
      );

      expect(_menuButton, findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('a pushed top-level page shows the menu, and it calls '
        'onOpen', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(
          home: _page(
            'Home',
            next: () => BgeTopLevelRoute(child: _page('Section')),
          ),
          onOpen: () => opened++,
          browserOwnsBack: true,
        ),
      );
      await _push(tester);

      expect(find.text('Section'), findsOneWidget);
      expect(_menuButton, findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      await tester.tap(_menuButton);
      expect(opened, 1);
    });

    testWidgets('a pushed child page shows no arrow', (tester) async {
      await tester.pumpWidget(
        _host(home: _page('Home'), browserOwnsBack: true),
      );
      await _push(tester);

      expect(find.text('Pushed'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      expect(_menuButton, findsNothing);
      // No leading control of any kind.
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('while a rail carries the menu, a pushed top-level page shows '
        'nothing', (tester) async {
      await tester.pumpWidget(
        _host(
          home: _page(
            'Home',
            next: () => BgeTopLevelRoute(child: _page('Section')),
          ),
          offersPageButton: false,
          browserOwnsBack: true,
        ),
      );
      await _push(tester);

      expect(find.text('Section'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
    });

    // #611: a cancel in a flow, such as the feedback review's, is an
    // action, not navigation, so it stays.
    testWidgets('an explicit leading is kept', (tester) async {
      await tester.pumpWidget(
        _host(
          home: _page(
            'Home',
            next: () => _page(
              'Review',
              implyLeading: false,
              leading: BackButton(onPressed: () {}),
            ),
          ),
          browserOwnsBack: true,
        ),
      );
      await _push(tester);

      expect(find.text('Review'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      expect(_menuButton, findsNothing);
    });

    testWidgets('an explicit leading wins on a top-level page too', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          home: _page(
            'Home',
            next: () => BgeTopLevelRoute(
              child: _page('Section', leading: const Icon(Icons.star)),
            ),
          ),
          browserOwnsBack: true,
        ),
      );
      await _push(tester);

      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(_menuButton, findsNothing);
    });

    testWidgets('automaticallyImplyLeading false on a top-level page shows '
        'nothing', (tester) async {
      await tester.pumpWidget(
        _host(
          home: _page(
            'Home',
            next: () => BgeTopLevelRoute(
              child: _page('Section', implyLeading: false),
            ),
          ),
          browserOwnsBack: true,
        ),
      );
      await _push(tester);

      expect(find.text('Section'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('a change to browserOwnsBack rebuilds the page', (
      tester,
    ) async {
      final host = GlobalKey<_MenuHostState>();
      await tester.pumpWidget(_hostWithState(host));
      await _push(tester);
      expect(find.byType(BackButton), findsOneWidget);

      host.currentState!.change(browserOwnsBack: true);
      await tester.pump();
      expect(find.byType(BackButton), findsNothing);

      host.currentState!.change(browserOwnsBack: false);
      await tester.pump();
      expect(find.byType(BackButton), findsOneWidget);
    });
  });

  group('BgeTopLevelRoute', () {
    testWidgets('isAt is true beneath one and false elsewhere', (
      tester,
    ) async {
      late BuildContext inside;
      late BuildContext outside;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              BgeTopLevelRoute(
                child: Builder(
                  builder: (context) {
                    inside = context;
                    return const SizedBox.shrink();
                  },
                ),
              ),
              Builder(
                builder: (context) {
                  outside = context;
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      );

      expect(BgeTopLevelRoute.isAt(inside), isTrue);
      expect(BgeTopLevelRoute.isAt(outside), isFalse);
    });

    // A marker carries nothing that can change, so a new one, as a route
    // builds each time its page is rebuilt, sends no notice to the pages
    // that read it.
    testWidgets('a new marker rebuilds nothing that reads it', (tester) async {
      var builds = 0;
      late StateSetter rebuildHost;
      // The same instance on every host build, so only a notice from the
      // marker could build it again.
      final reader = Builder(
        builder: (context) {
          BgeTopLevelRoute.isAt(context);
          builds++;
          return const SizedBox.shrink();
        },
      );
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            rebuildHost = setState;
            return BgeTopLevelRoute(child: reader);
          },
        ),
      );
      expect(builds, 1);

      rebuildHost(() {});
      await tester.pump();

      expect(builds, 1);
    });
  });

  group('BgeMenuButton', () {
    testWidgets('shows the menu icon, is named by openAppDrawerTooltip, and '
        'calls onPressed', (tester) async {
      final handle = tester.ensureSemantics();
      var pressed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BgeMenuButton(onPressed: () => pressed++)),
        ),
      );

      expect(find.byIcon(Icons.menu), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(BgeMenuButton)),
        matchesSemantics(
          tooltip: const DefaultMaterialLocalizations().openAppDrawerTooltip,
          isButton: true,
          hasTapAction: true,
          hasFocusAction: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
        ),
      );
      await tester.tap(find.byType(BgeMenuButton));
      expect(pressed, 1);
      handle.dispose();
    });
  });
}
