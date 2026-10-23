import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';
import '../support/stub_feedback_service.dart';

/// The crash flow sits above the router's Navigator, where no route owns
/// keyboard focus, so it holds focus itself while a draft is pending: the
/// app behind the barrier can't take what is typed, and Tab stays in the
/// flow.
void main() {
  setUp(ShellObservability.initialize);
  tearDown(() async => ShellObservability.reset());

  UncaughtErrorRecord record() => UncaughtErrorRecord.capture(
    StateError('bad state'),
    StackTrace.fromString('#0 main (file.dart:1)'),
  );

  late FeedbackUncaughtErrorReporter reporter;
  late TextEditingController field;
  late FocusNode fieldFocus;

  /// Boots [BgeApp] to its sign-in screen.
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
    reporter = FeedbackUncaughtErrorReporter(service: StubFeedbackService());
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
    return cubit;
  }

  /// Boots [BgeApp] and opens a screen whose field asks for focus, as the
  /// sign-in form does. The test harness's own screens are placeholders
  /// with nothing to focus.
  Future<void> pumpAppWithField(
    WidgetTester tester, {
    List<ServerConfig> recoveredServers = const [],
  }) async {
    await pumpApp(tester, recoveredServers: recoveredServers);
    field = TextEditingController();
    fieldFocus = FocusNode();
    addTearDown(field.dispose);
    addTearDown(fieldFocus.dispose);

    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: TextField(
                  controller: field,
                  focusNode: fieldFocus,
                  autofocus: true,
                ),
              ),
            ),
          ),
    );
    await tester.pumpAndSettle();
  }

  /// The focus scope holding whichever crash surface is showing: its own,
  /// never one that also holds the app behind it.
  FocusNode crashFlowFocus(WidgetTester tester, Type surface) {
    final scope = FocusScope.of(tester.element(find.byType(surface)));
    expect(fieldFocus.ancestors, isNot(contains(scope)));
    return scope;
  }

  testWidgets('keeps typing and Tab away from the app behind the prompt', (
    tester,
  ) async {
    await pumpAppWithField(tester);
    expect(fieldFocus.hasFocus, isTrue);

    reporter.report(record());
    await tester.pumpAndSettle();

    expect(fieldFocus.hasFocus, isFalse);
    expect(crashFlowFocus(tester, CrashReportPrompt).hasFocus, isTrue);

    tester.testTextInput.enterText('typed behind the barrier');
    await tester.pump();
    expect(field.text, isEmpty);

    // More presses than the prompt has controls, so Tab has wrapped.
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(crashFlowFocus(tester, CrashReportPrompt).hasFocus, isTrue);
    }
  });

  testWidgets('keeps focus in the flow as it swaps to the review surface '
      'and back', (tester) async {
    await pumpAppWithField(tester);
    reporter.report(record());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
    await tester.pumpAndSettle();
    expect(crashFlowFocus(tester, FeedbackReviewScreen).hasFocus, isTrue);
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(crashFlowFocus(tester, FeedbackReviewScreen).hasFocus, isTrue);
      expect(fieldFocus.hasFocus, isFalse);
    }

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(crashFlowFocus(tester, CrashReportPrompt).hasFocus, isTrue);
    expect(fieldFocus.hasFocus, isFalse);
  });

  testWidgets('gives focus back when the draft is discarded', (tester) async {
    await pumpAppWithField(tester);
    reporter.report(record());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(CrashReportPrompt.discardButtonKey));
    await tester.pumpAndSettle();

    expect(find.byType(CrashReportPrompt), findsNothing);
    expect(fieldFocus.hasFocus, isTrue);
  });

  // Where focus was when the crash arrived, the sign-in screen, is gone
  // once the restored session redirects home.
  testWidgets('gives focus to the app when a redirect replaced the screen '
      'behind it', (tester) async {
    final cubit = await pumpApp(tester);
    reporter.report(record());
    await tester.pumpAndSettle();
    cubit.onAuthenticated();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(CrashReportPrompt.discardButtonKey));
    await tester.pumpAndSettle();
    expect(find.byType(CrashReportPrompt), findsNothing);

    // The home placeholder has nothing for Tab to reach, so this checks
    // that focus is on the screen showing, not one that is gone.
    final focus = FocusManager.instance.primaryFocus!;
    expect(focus.context!.mounted, isTrue);
    expect(
      [focus, ...focus.ancestors],
      contains(
        tester.state<NavigatorState>(find.byType(Navigator).first).focusNode,
      ),
    );
  });

  // The recovery notice sits above the crash flow and shuts it out of focus
  // until it is acknowledged.
  testWidgets('a crash under the recovery notice takes focus once the notice '
      'is acknowledged, and gives it to the app when discarded', (
    tester,
  ) async {
    await pumpAppWithField(
      tester,
      recoveredServers: [
        ServerConfig(
          id: 'local-game-night',
          displayName: 'Game Night',
          serverUrl: 'https://api.example.com',
          connectionState: ConnectionState.active,
          bgeServerId: 'bge-game-night',
          cachedIdentity: serverIdentity(),
          lastIdentityFetchedAt: DateTime.utc(2026, 10, 20),
        ),
      ],
    );
    reporter.report(record());
    await tester.pumpAndSettle();
    expect(crashFlowFocus(tester, CrashReportPrompt).hasFocus, isFalse);

    await tester.tap(find.byKey(DatabaseRecoveryNotice.acknowledgeButtonKey));
    await tester.pumpAndSettle();
    expect(crashFlowFocus(tester, CrashReportPrompt).hasFocus, isTrue);

    await tester.tap(find.byKey(CrashReportPrompt.discardButtonKey));
    await tester.pumpAndSettle();
    // Where focus was before the crash, the notice's button, is gone, so
    // the app's Navigator gets it, and Tab reaches the field from there.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(fieldFocus.hasFocus, isTrue);
  });
}
