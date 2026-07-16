import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import '../support/fake_platform_bootstrap.dart';

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

  testWidgets('a pending crash draft surfaces the prompt as a modal '
      '(barrier blocks the app behind)', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    expect(find.byType(CrashReportPrompt), findsNothing);
    // MaterialApp's own route already keeps a ModalBarrier in the tree,
    // so assert the prompt adds exactly one MORE barrier rather than
    // assuming a zero baseline.
    final baselineBarriers = find.byType(ModalBarrier).evaluate().length;

    reporter.report(record());
    await tester.pump();

    expect(find.byType(CrashReportPrompt), findsOneWidget);
    expect(
      find.byType(ModalBarrier).evaluate().length,
      baselineBarriers + 1,
      reason: 'the pending prompt adds its own modal barrier over the app',
    );
  });

  testWidgets('while a draft is pending the underlying app is removed '
      'from the semantics tree (modal for assistive tech)', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();

    final blocker = find.byKey(BgeApp.contentSemanticsBlockerKey);
    BlockSemantics blockSemantics() => tester.widget<BlockSemantics>(blocker);

    // The content wrapper is present but not blocking before a crash.
    expect(blockSemantics().blocking, isFalse);

    reporter.report(record());
    await tester.pump();

    // Once the modal prompt is up, the wrapper blocks — dropping the
    // underlying app (painted before it) from the semantics tree.
    expect(blockSemantics().blocking, isTrue);
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

  testWidgets('the comment field is editable in the real wiring and the '
      'outcome window closes after submission', (tester) async {
    // Regression: the prompt mounts in MaterialApp.builder — ABOVE the
    // Navigator, so the Navigator's Overlay is not an ancestor. Without
    // an Overlay of its own, focusing the comment field crashes
    // EditableText ("No Overlay widget found"), and the crash cascade
    // (captured by the hooks → reporter.report → slot refilled)
    // re-summons the prompt, so the outcome window's close button
    // appears dead.
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();

    // Focus + type — requires an Overlay ancestor for the selection
    // handles/toolbar.
    await tester.tap(find.byKey(CrashReportPrompt.commentFieldKey));
    await tester.pump();
    await tester.enterText(
      find.byKey(CrashReportPrompt.commentFieldKey),
      'happened right after account creation',
    );
    await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
    // Plain pumps — the app behind the prompt animates indefinitely
    // (splash spinner), so pumpAndSettle would never settle.
    await tester.pump();
    await tester.pump();

    expect(find.byKey(CrashReportPrompt.sentConfirmationKey), findsOneWidget);

    // Close on the outcome window dismisses for good — no re-summon.
    await tester.tap(find.byKey(CrashReportPrompt.discardButtonKey));
    await tester.pump();
    expect(find.byType(CrashReportPrompt), findsNothing);
    expect(reporter.pendingCrashReport.value, isNull);
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
