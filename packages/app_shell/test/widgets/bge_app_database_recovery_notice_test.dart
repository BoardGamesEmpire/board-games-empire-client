import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';
import '../support/stub_feedback_service.dart';

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

  // The crash flow's back handler takes priority when it mounts, which is
  // after the notice's when the crash arrives under it.
  testWidgets('system back acknowledges it ahead of a crash prompt that '
      'arrived under it, and leaves the crash report pending', (tester) async {
    ShellObservability.initialize();
    addTearDown(ShellObservability.reset);
    final reporter = FeedbackUncaughtErrorReporter(
      service: StubFeedbackService(),
    );
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        outcomes: [
          BootstrapResult(
            hasServer: true,
            recoveredServers: [_server('Game Night')],
          ),
        ],
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
    reporter.report(
      UncaughtErrorRecord.capture(
        StateError('bad state'),
        StackTrace.fromString('#0 main (file.dart:1)'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    // A second press is the crash prompt's first: it arms, never discards.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(reporter.pendingCrashReport.value, isNotNull);
    expect(find.byType(CrashReportPrompt), findsOneWidget);
  });

  testWidgets('can be read to the end and acknowledged in a short viewport '
      'with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(
      tester,
      recoveredServers: [_server('Game Night'), _server('Club')],
    );

    await tester.ensureVisible(find.textContaining('Game Night, Club'));
    await tester.ensureVisible(
      find.byKey(DatabaseRecoveryNotice.acknowledgeButtonKey),
    );
    await tester.tap(find.byKey(DatabaseRecoveryNotice.acknowledgeButtonKey));
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

  group('keyboard', () {
    // The sign-in form asks for focus as it appears. BgeApp's test harness
    // shows a placeholder there, so the notice wraps a field of its own.
    late AppBootstrapCubit cubit;
    late TextEditingController field;
    late FocusNode fieldFocus;

    Future<void> pumpNoticeOverField(WidgetTester tester) async {
      cubit = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(
          outcomes: [
            BootstrapResult(
              hasServer: true,
              recoveredServers: [_server('Game Night')],
            ),
          ],
        ),
        hydratedStorageInitializer: (_) async {},
      );
      field = TextEditingController();
      fieldFocus = FocusNode();
      addTearDown(cubit.close);
      addTearDown(field.dispose);
      addTearDown(fieldFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: ShellLocalizations.localizationsDelegates,
          builder: (context, child) => DatabaseRecoveryNotice(
            bootstrapCubit: cubit,
            backButtonDispatcher: null,
            child: child!,
          ),
          home: Scaffold(
            body: TextField(
              controller: field,
              focusNode: fieldFocus,
              autofocus: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fieldFocus.hasFocus, isTrue);

      await cubit.initialize();
      await tester.pumpAndSettle();
    }

    FocusNode? acknowledgeFocus(WidgetTester tester) => Focus.of(
      tester.element(
        find.descendant(
          of: find.byKey(DatabaseRecoveryNotice.acknowledgeButtonKey),
          matching: find.byType(Text),
        ),
      ),
    );

    testWidgets('keeps typing and Tab away from the app behind it', (
      tester,
    ) async {
      await pumpNoticeOverField(tester);

      expect(fieldFocus.hasFocus, isFalse);
      expect(acknowledgeFocus(tester)!.hasPrimaryFocus, isTrue);

      tester.testTextInput.enterText('typed behind the notice');
      await tester.pump();
      expect(field.text, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(acknowledgeFocus(tester)!.hasPrimaryFocus, isTrue);
    });

    testWidgets('is acknowledged from the keyboard, and gives focus back', (
      tester,
    ) async {
      await pumpNoticeOverField(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(fieldFocus.hasFocus, isTrue);
    });
  });
}
