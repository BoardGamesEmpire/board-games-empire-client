import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _reason = "Available when you're online";

Widget _host(ValueNotifier<bool> offline, List<String> picked) => MaterialApp(
  theme: BgeTheme.light(),
  builder: (context, child) => ValueListenableBuilder<bool>(
    valueListenable: offline,
    child: child,
    builder: (context, isOffline, child) => BgeConnectivityScope(
      offline: isOffline,
      noticeShowing: isOffline,
      onlineOnlyReason: _reason,
      child: child!,
    ),
  ),
  home: Scaffold(
    body: Center(
      child: PopupMenuButton<String>(
        key: const Key('menu'),
        onSelected: picked.add,
        itemBuilder: (_) => const [
          BgeOnlineOnlyPopupMenuItem<String>(
            key: Key('item'),
            value: 'connect',
            label: 'Connect',
          ),
        ],
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('menu')));
  await tester.pumpAndSettle();
}

void main() {
  late ValueNotifier<bool> offline;
  late List<String> picked;
  final item = find.byKey(const Key('item'));

  setUp(() {
    offline = ValueNotifier(false);
    picked = [];
  });
  tearDown(() => offline.dispose());

  testWidgets('online it is a plain enabled item', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(offline, picked));
    await _open(tester);

    expect(find.text(_reason), findsNothing);
    expect(
      tester.getSemantics(item),
      matchesSemantics(
        label: 'Connect',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(picked, ['connect']);
    handle.dispose();
  });

  testWidgets('opened offline it is disabled with the reason', (tester) async {
    final handle = tester.ensureSemantics();
    offline.value = true;
    await tester.pumpWidget(_host(offline, picked));
    await _open(tester);

    expect(
      tester.getSemantics(item),
      matchesSemantics(
        label: 'Connect\n$_reason',
        isButton: true,
        hasEnabledState: true,
      ),
    );
    await tester.tap(item, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
    handle.dispose();
  });

  testWidgets('a drop with the menu open disables it and gives the reason', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(offline, picked));
    await _open(tester);

    offline.value = true;
    await tester.pump();
    await tester.pump();

    expect(
      tester.getSemantics(item),
      matchesSemantics(
        label: 'Connect\n$_reason',
        isButton: true,
        hasEnabledState: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a return with the menu open enables it and drops the reason', (
    tester,
  ) async {
    offline.value = true;
    await tester.pumpWidget(_host(offline, picked));
    await _open(tester);

    offline.value = false;
    await tester.pump();

    expect(find.text(_reason), findsNothing);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(picked, ['connect']);
  });
}
