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

      expect(
        tester.getSemantics(_menuButton).tooltip,
        const DefaultMaterialLocalizations().openAppDrawerTooltip,
      );
      handle.dispose();
    });
  });
}
