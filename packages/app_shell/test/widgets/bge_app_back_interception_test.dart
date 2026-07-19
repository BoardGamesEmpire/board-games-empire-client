import 'package:app_shell/app_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

import '../support/fake_platform_bootstrap.dart';

/// Pinned (#106): while the crash flow (#69/#76) is up, system back is
/// intercepted at the router's [BackButtonDispatcher] by a
/// [RouterBackInterceptor] mounted with the overlay — it never reaches the
/// router hidden under the crash barrier.
///
/// - Review surface open → back bounces to the compact prompt (matching
///   the visible `BackButton`), keeping the draft.
/// - Compact prompt → the first back is intercepted-and-ignored, arming a
///   localized live-region dismiss hint; a second back within
///   [BgeApp.crashPromptBackDismissWindow] discards the draft (clearing
///   both RAM slots, like the Don't-send button). After the window
///   elapses, the prompt returns to intercept-and-ignore.
/// - The interceptor is mounted only while a draft is pending; once the
///   flow closes, back handling belongs to the router again.
void main() {
  setUp(ShellObservability.initialize);
  tearDown(() async => ShellObservability.reset());

  // Parameterized because FeedbackReport is freezed (value equality) and
  // the stub service maps record.message straight onto report.message with
  // a constant correlationKey: two reports built from equal records are
  // `==`, and ValueNotifier's setter short-circuits on `==` — the change
  // listener never fires. Production is immune (the real service stamps a
  // unique cuid2 correlationKey per build), but tests simulating "a new
  // crash" must make the draft value-distinct or nothing is notified.
  UncaughtErrorRecord record([String message = 'bad state']) =>
      UncaughtErrorRecord.capture(
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

  /// Simulates the platform's system back (Android hardware/gesture back)
  /// exactly as it arrives in production: a `popRoute` method call on the
  /// navigation channel → `WidgetsBinding.handlePopRoute` → the observer
  /// chain → the router's root back-button dispatcher → prioritized
  /// children (the interceptor).
  Future<void> systemBack(WidgetTester tester) async {
    final message = SystemChannels.navigation.codec.encodeMethodCall(
      const MethodCall('popRoute'),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      message,
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('the back interceptor is mounted only while a crash draft '
      'is pending', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    expect(find.byType(RouterBackInterceptor), findsNothing);

    reporter.report(record());
    await tester.pump();
    expect(find.byType(RouterBackInterceptor), findsOneWidget);

    reporter.clearPendingCrashReport();
    await tester.pump();
    expect(find.byType(RouterBackInterceptor), findsNothing);
  });

  testWidgets('system back on the review surface returns to the compact '
      'prompt and keeps the draft', (tester) async {
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
    expect(find.byType(FeedbackReviewScreen), findsOneWidget);

    await systemBack(tester);

    expect(find.byType(FeedbackReviewScreen), findsNothing);
    expect(find.byType(CrashReportPrompt), findsOneWidget);
    expect(reporter.pendingCrashReport.value, isNotNull);
  });

  testWidgets('a first system back on the prompt is intercepted and shows '
      'the dismiss hint', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();
    expect(find.byKey(CrashReportPrompt.dismissHintKey), findsNothing);

    await systemBack(tester);

    expect(
      find.byType(CrashReportPrompt),
      findsOneWidget,
      reason: 'a stray back must not dismiss a crash prompt',
    );
    expect(find.byKey(CrashReportPrompt.dismissHintKey), findsOneWidget);
    expect(reporter.pendingCrashReport.value, isNotNull);

    // Let the disarm timer fire so the test ends with no pending timers.
    await tester.pump(BgeApp.crashPromptBackDismissWindow);
  });

  testWidgets('the armed dismiss disarms after the window; a later back '
      're-arms instead of discarding', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();

    await systemBack(tester);
    expect(find.byKey(CrashReportPrompt.dismissHintKey), findsOneWidget);

    await tester.pump(BgeApp.crashPromptBackDismissWindow);
    expect(
      find.byKey(CrashReportPrompt.dismissHintKey),
      findsNothing,
      reason:
          'the dismiss window elapsed — back is intercept-and-ignore '
          'again',
    );

    await systemBack(tester);
    expect(
      find.byType(CrashReportPrompt),
      findsOneWidget,
      reason: 'a back after the window re-arms; it must not discard',
    );
    expect(find.byKey(CrashReportPrompt.dismissHintKey), findsOneWidget);
    expect(reporter.pendingCrashReport.value, isNotNull);

    await tester.pump(BgeApp.crashPromptBackDismissWindow);
  });

  testWidgets('a second system back within the window discards the draft '
      'and clears both RAM slots', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    ShellObservability.recordUncaughtError(record());
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();

    await systemBack(tester);
    await systemBack(tester);

    expect(find.byType(CrashReportPrompt), findsNothing);
    expect(find.byType(FeedbackReviewScreen), findsNothing);
    expect(find.byType(RouterBackInterceptor), findsNothing);
    expect(reporter.pendingCrashReport.value, isNull);
    expect(
      ShellObservability.lastUncaughtError.value,
      isNull,
      reason:
          'a double-back discard empties the last-error slot (#34 '
          'contract), matching the Don\'t-send button',
    );
  });

  testWidgets('a new crash disarms a pending dismiss — the second back '
      'must not discard a draft it was not armed on', (tester) async {
    final (cubit, reporter) = buildDeps();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, feedbackReporter: reporter),
    );
    await tester.pump();
    reporter.report(record());
    await tester.pump();

    await systemBack(tester);
    expect(find.byKey(CrashReportPrompt.dismissHintKey), findsOneWidget);

    // Distinct message: a value-equal draft would be swallowed by
    // ValueNotifier's `==` short-circuit — see the record() helper doc.
    reporter.report(record('a newer crash'));
    await tester.pump();
    expect(
      find.byKey(CrashReportPrompt.dismissHintKey),
      findsNothing,
      reason: 'the armed window belongs to the draft it was armed on',
    );

    await systemBack(tester);
    expect(
      find.byType(CrashReportPrompt),
      findsOneWidget,
      reason: 'first back on the new draft re-arms; it must not discard',
    );
    expect(reporter.pendingCrashReport.value, isNotNull);

    await tester.pump(BgeApp.crashPromptBackDismissWindow);
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
