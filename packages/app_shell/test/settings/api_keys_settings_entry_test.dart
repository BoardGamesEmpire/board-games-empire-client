import 'package:api_keys/api_keys.dart';
import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _pushedKey = Key('api_keys_route_marker');

void main() {
  Future<void> pumpEntry(
    WidgetTester tester, {
    required String serverName,
    Size size = const Size(800, 600),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: ApiKeysSettingsEntry(serverName: serverName).build(context),
          ),
        ),
        GoRoute(
          path: AppRoutes.settingsApiKeys,
          builder: (_, _) => const Scaffold(body: SizedBox(key: _pushedKey)),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: const [
          ...ShellLocalizations.localizationsDelegates,
          ApiKeysLocalizations.delegate,
        ],
        supportedLocales: ShellLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('has the stable id apiKeys', () {
    expect(const ApiKeysSettingsEntry(serverName: 'x').id, 'apiKeys');
  });

  testWidgets('the entry opens /settings/api-keys and names the server', (
    tester,
  ) async {
    await pumpEntry(tester, serverName: 'Game Night HQ');

    expect(find.byKey(const Key('settings_api_keys')), findsOneWidget);
    expect(find.text('API keys'), findsOneWidget);
    expect(
      find.text('Keys for programs to use Game Night HQ as you'),
      findsOneWidget,
    );

    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();

    expect(AppRoutes.settingsApiKeys, '/settings/api-keys');
    expect(find.byKey(_pushedKey), findsOneWidget);
  });

  testWidgets('fits at 320dp and 2.0× text scale with a long server name', (
    tester,
  ) async {
    await pumpEntry(
      tester,
      serverName: List.filled(60, 'n').join(),
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('a focused API keys row is ringed', (tester) async {
    await pumpEntry(tester, serverName: 'Game Night HQ');

    expect(
      await keyboardFocusShowsRing(tester, find.text('API keys')),
      isTrue,
    );
  });
}
