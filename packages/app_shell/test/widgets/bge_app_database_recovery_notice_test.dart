import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

ServerConfig _server(String displayName) => ServerConfig(
  id: 'local-$displayName',
  displayName: displayName,
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.active,
  bgeServerId: 'bge-$displayName',
  cachedIdentity: serverIdentity(),
  lastIdentityFetchedAt: DateTime.utc(2026, 10, 20),
);

/// #428: a server database that no key on this device could open is rebuilt
/// during boot, and the user's unsent changes on it are gone. The shell says
/// so once, in a notice the user acknowledges.
void main() {
  Future<AppBootstrapCubit> pumpApp(
    WidgetTester tester, {
    List<ServerConfig> recoveredServers = const [],
  }) async {
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        outcomes: [
          BootstrapResult(hasServer: true, recoveredServers: recoveredServers),
        ],
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    return cubit;
  }

  testWidgets('names the server whose data was rebuilt', (tester) async {
    await pumpApp(tester, recoveredServers: [_server('Game Night')]);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('Game Night'), findsOneWidget);
  });

  testWidgets('names every server whose data was rebuilt', (tester) async {
    await pumpApp(
      tester,
      recoveredServers: [_server('Game Night'), _server('Club')],
    );

    expect(find.textContaining('Game Night, Club'), findsOneWidget);
  });

  testWidgets('shows nothing after a boot that rebuilt nothing', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('stays up across a change of screen until acknowledged', (
    tester,
  ) async {
    final cubit = await pumpApp(
      tester,
      recoveredServers: [_server('Game Night')],
    );

    cubit.onAuthenticated();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.byKey(DatabaseRecoveryNotice.acknowledgeButtonKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('system back acknowledges it', (tester) async {
    await pumpApp(tester, recoveredServers: [_server('Game Night')]);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('is announced as a dialog, and hides the app behind it from '
      'assistive technology', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester, recoveredServers: [_server('Game Night')]);

    final i18n = ShellLocalizations.of(
      tester.element(find.byType(AlertDialog)),
    );
    final routeName = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && (widget.properties.namesRoute ?? false),
      ),
    );
    expect(
      tester.getSemantics(routeName),
      isSemantics(
        label: i18n.shellDatabaseRecoveredTitle,
        namesRoute: true,
        scopesRoute: true,
      ),
    );
    // The auth placeholder is the screen behind the notice.
    expect(find.bySemanticsLabel(i18n.shellPlaceholderBody), findsNothing);
    semantics.dispose();
  });

  testWidgets('leaves the app reachable by assistive technology once '
      'acknowledged', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester, recoveredServers: [_server('Game Night')]);
    final i18n = ShellLocalizations.of(
      tester.element(find.byType(AlertDialog)),
    );

    await tester.tap(find.byKey(DatabaseRecoveryNotice.acknowledgeButtonKey));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel(i18n.shellPlaceholderBody), findsOneWidget);
    semantics.dispose();
  });
}
