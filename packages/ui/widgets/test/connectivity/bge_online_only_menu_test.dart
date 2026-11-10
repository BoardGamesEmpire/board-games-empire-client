import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _reason = "Available when you're online";

Widget _host(ValueNotifier<bool> offline) => MaterialApp(
  theme: BgeTheme.light(),
  home: ValueListenableBuilder<bool>(
    valueListenable: offline,
    builder: (context, isOffline, _) => BgeConnectivityScope(
      offline: isOffline,
      noticeShowing: isOffline,
      onlineOnlyReason: _reason,
      child: Scaffold(
        body: Center(
          child: BgeOnlineOnlyMenu(
            builder: (context, menu) => MenuAnchor(
              controller: menu,
              menuChildren: [
                MenuItemButton(
                  onPressed: isOffline ? null : () {},
                  child: const BgeOnlineOnlyLabel('Delete'),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                key: const Key('anchor'),
                icon: const Icon(Icons.more_vert),
                onPressed: controller.isOpen
                    ? controller.close
                    : controller.open,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a menu open as the connection drops closes', (tester) async {
    final offline = ValueNotifier(false);
    addTearDown(offline.dispose);
    await tester.pumpWidget(_host(offline));
    await tester.tap(find.byKey(const Key('anchor')));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);

    offline.value = true;
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('a focused item going disabled leaves focus a Tab can leave', (
    tester,
  ) async {
    final offline = ValueNotifier(false);
    addTearDown(offline.dispose);
    await tester.pumpWidget(_host(offline));
    await tester.tap(find.byKey(const Key('anchor')));
    await tester.pumpAndSettle();
    final item = Focus.of(tester.element(find.text('Delete')))..requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, item);
    expect(item.hasPrimaryFocus, isTrue);

    offline.value = true;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Delete'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    final now = FocusManager.instance.primaryFocus;
    expect(tester.takeException(), isNull);
    expect(now, isNotNull);
    expect(now, isNot(item));
    expect(now, isNot(isA<FocusScopeNode>()));
    expect(now!.context, isNotNull);
  });

  testWidgets('a menu opened while offline stays open, to be read', (
    tester,
  ) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    await tester.pumpWidget(_host(offline));
    await tester.tap(find.byKey(const Key('anchor')));
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    expect(find.text(_reason), findsOneWidget);
  });

  testWidgets('coming back online leaves an open menu open', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    await tester.pumpWidget(_host(offline));
    await tester.tap(find.byKey(const Key('anchor')));
    await tester.pumpAndSettle();

    offline.value = false;
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    expect(find.text(_reason), findsNothing);
  });
}
