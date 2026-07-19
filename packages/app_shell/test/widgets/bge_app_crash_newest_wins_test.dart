import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import '../support/fake_platform_bootstrap.dart';

/// Pinned (#105): the crash flow honors newest-crash-wins even while the
/// review surface is open. `BgeApp`'s review slot remembers the draft
/// **instance** it was opened for; when a second uncaught error overwrites
/// `FeedbackUncaughtErrorReporter.pendingCrashReport` mid-review, the slot
/// is cleared and the flow bounces back to the compact prompt — which
/// reads the live draft each build, so the newer crash is what the user
/// sees and (if they choose) sends. The first draft is dropped, matching
/// the reporter's single-slot newest-wins contract.
void main() {
  setUp(ShellObservability.initialize);
  tearDown(() async => ShellObservability.reset());

  UncaughtErrorRecord record(String message) => UncaughtErrorRecord.capture(
    StateError(message),
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

  testWidgets('a second crash while the review surface is open bounces '
      'back to the compact prompt showing the newer draft', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record('first crash'));
    await tester.pump();
    await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
    await tester.pump();
    expect(find.byType(FeedbackReviewScreen), findsOneWidget);

    reporter.report(record('second crash'));
    await tester.pump();

    expect(
      find.byType(FeedbackReviewScreen),
      findsNothing,
      reason: 'a draft identity change mid-review closes the review surface',
    );
    expect(find.byType(CrashReportPrompt), findsOneWidget);
    expect(
      find.textContaining('second crash'),
      findsOneWidget,
      reason: 'the bounced-to prompt reads the live draft — the newer crash',
    );
    expect(find.textContaining('first crash'), findsNothing);
    expect(
      reporter.pendingCrashReport.value?.message,
      contains('second crash'),
    );
  });

  testWidgets('re-opening review after the bounce reviews the newer draft', (
    tester,
  ) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record('first crash'));
    await tester.pump();
    await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
    await tester.pump();
    reporter.report(record('second crash'));
    await tester.pump();

    await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
    await tester.pump();

    expect(find.byType(FeedbackReviewScreen), findsOneWidget);
    expect(find.textContaining('second crash'), findsWidgets);
    expect(find.textContaining('first crash'), findsNothing);
  });

  testWidgets('a second crash while only the compact prompt is open shows '
      'the newer draft in place (pins the pre-#105 live read)', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record('first crash'));
    await tester.pump();

    reporter.report(record('second crash'));
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsOneWidget);
    expect(find.textContaining('second crash'), findsOneWidget);
    expect(find.textContaining('first crash'), findsNothing);
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
