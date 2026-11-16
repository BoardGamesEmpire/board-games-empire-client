import 'package:app_shell/app_shell.dart';
import 'package:data_export/data_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _pushedKey = Key('export_route_marker');

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
            body: DataExportSettingsEntry(serverName: serverName)
                .build(context),
          ),
        ),
        GoRoute(
          path: AppRoutes.settingsExport,
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
          DataExportLocalizations.delegate,
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

  test('has the stable id dataExport', () {
    expect(const DataExportSettingsEntry(serverName: 'x').id, 'dataExport');
  });

  testWidgets('shows the title and the server name', (tester) async {
    await pumpEntry(tester, serverName: 'Game Night HQ');

    expect(find.text('Export your data'), findsOneWidget);
    expect(find.text('A copy of your data on Game Night HQ'), findsOneWidget);
  });

  testWidgets('tapping pushes /settings/export', (tester) async {
    await pumpEntry(tester, serverName: 'Game Night HQ');

    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();

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
}
