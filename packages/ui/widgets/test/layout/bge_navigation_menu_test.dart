import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

const _pushKey = Key('push');

Widget _page(String title, {Widget? leading, bool implyLeading = true}) =>
    BgePage(
      title: Text(title),
      leading: leading,
      automaticallyImplyLeading: implyLeading,
      child: Builder(
        builder: (context) => TextButton(
          key: _pushKey,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => _page('Pushed')),
          ),
          child: const Text('Push'),
        ),
      ),
    );

Widget _host({
  required Widget home,
  VoidCallback? onOpen,
  bool offersPageButton = true,
  bool withMenu = true,
}) => MaterialApp(
  home: home,
  builder: (context, child) => withMenu
      ? BgeNavigationMenu(
          onOpen: onOpen ?? () {},
          offersPageButton: offersPageButton,
          child: child!,
        )
      : child!,
);

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
  bool _present = true;

  void change({
    VoidCallback? onOpen,
    bool? offersPageButton,
    bool? present,
  }) => setState(() {
    _onOpen = onOpen ?? _onOpen;
    _offersPageButton = offersPageButton ?? _offersPageButton;
    _present = present ?? _present;
  });

  @override
  Widget build(BuildContext context) => _present
      ? BgeNavigationMenu(
          onOpen: _onOpen,
          offersPageButton: _offersPageButton,
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
