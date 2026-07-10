import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import '../support/fake_platform_bootstrap.dart';

/// Red-phase integration tests for the crash-prompt wiring inside
/// `BgeApp` (issue #69).
///
/// Pinned: `BgeApp` gains an optional `feedbackReporter`. When supplied,
/// the app listens to `pendingCrashReport` and overlays
/// [CrashReportPrompt] when a draft lands; discard clears **both** RAM
/// slots — the reporter's draft and `ShellObservability`'s last-error
/// record ("the user declined" per the #34 contract). With no reporter
/// (the default, and every pre-#69 construction) nothing changes.
void main() {
  setUp(ShellObservability.initialize);
  tearDown(() async => ShellObservability.reset());

  UncaughtErrorRecord record() => UncaughtErrorRecord.capture(
    StateError('bad state'),
    StackTrace.fromString('#0 main (file.dart:1)'),
  );

  (AppBootstrapCubit, FeedbackUncaughtErrorReporter) buildDeps() {
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(),
      hydratedStorageInitializer: (_) async {},
    );
    final reporter = FeedbackUncaughtErrorReporter(
      service: _StubFeedbackService(),
    );
    return (cubit, reporter);
  }

  testWidgets('a pending crash draft surfaces the prompt', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    expect(find.byType(CrashReportPrompt), findsNothing);

    reporter.report(record());
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsOneWidget);
  });

  testWidgets('discard dismisses the prompt and clears both RAM slots', (
    tester,
  ) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    ShellObservability.recordUncaughtError(record());
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    reporter.report(record());
    await tester.pump();

    await tester.tap(find.byKey(CrashReportPrompt.discardButtonKey));
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsNothing);
    expect(reporter.pendingCrashReport.value, isNull);
    expect(
      ShellObservability.lastUncaughtError.value,
      isNull,
      reason:
          'declining a report empties the last-error slot (#34 '
          'contract: clearUncaughtError on decline)',
    );
  });

  testWidgets('no reporter, no prompt machinery — pre-#69 constructions '
      'are untouched', (tester) async {
    final (cubit, _) = buildDeps();
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsNothing);
  });
}

class _StubFeedbackService implements FeedbackService {
  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? correlationKey,
  }) => FeedbackReport(
    category: category,
    severity: severity ?? FeedbackSeverity.critical,
    message: errorMessage ?? 'crash',
    stackTrace: stackTrace,
    title: title,
    correlationKey: 'stub-key',
  );

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) async =>
      FeedbackSubmitResult.sent;

  @override
  Future<int> drainPending() async => 0;
}
