import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import '../support/fake_platform_bootstrap.dart';

/// Pinned (#76): from a pending crash draft, `CrashReportPrompt`'s
/// "Review details" affordance swaps the compact prompt for the full
/// [FeedbackReviewScreen] *in the same overlay* (a route would render
/// under the crash barrier). Backing out returns to the prompt; sending
/// then closing clears both RAM slots — the reporter's draft and
/// `ShellObservability`'s last-error record — exactly as discard does in
/// the #69 flow.
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

  testWidgets('"Review details" swaps the compact prompt for the full '
      'review surface', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsOneWidget);
    expect(find.byType(FeedbackReviewScreen), findsNothing);

    await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
    await tester.pump();

    expect(find.byType(FeedbackReviewScreen), findsOneWidget);
    expect(find.byType(CrashReportPrompt), findsNothing);
  });

  testWidgets('backing out of review returns to the compact prompt and '
      'keeps the draft', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();
    await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
    await tester.pump();

    await tester.tap(find.byKey(FeedbackReviewScreen.backButtonKey));
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsOneWidget);
    expect(find.byType(FeedbackReviewScreen), findsNothing);
    expect(reporter.pendingCrashReport.value, isNotNull);
  });

  testWidgets('sending from the review surface then closing clears both '
      'RAM slots', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    ShellObservability.recordUncaughtError(record());
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();
    await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
    await tester.pump();

    await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
    // Plain pumps — the app behind the overlay animates indefinitely
    // (splash spinner), so pumpAndSettle would never settle.
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(FeedbackReviewScreen.sentConfirmationKey),
      findsOneWidget,
    );

    await tester.tap(find.byKey(FeedbackReviewScreen.closeButtonKey));
    await tester.pump();

    expect(find.byType(FeedbackReviewScreen), findsNothing);
    expect(find.byType(CrashReportPrompt), findsNothing);
    expect(reporter.pendingCrashReport.value, isNull);
    expect(
      ShellObservability.lastUncaughtError.value,
      isNull,
      reason:
          'closing after a sent outcome empties the last-error slot '
          '(#34 contract), matching #69 discard',
    );
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
