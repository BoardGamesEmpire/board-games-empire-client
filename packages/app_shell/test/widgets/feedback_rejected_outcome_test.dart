// packages/app_shell/test/widgets/feedback_rejected_outcome_test.dart
import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:app_shell/src/widgets/crash_report_prompt.dart';
import 'package:app_shell/src/widgets/feedback_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// #97 Q11: a **permanent** server rejection renders its own honest
/// outcome — the report was neither sent NOR saved for later, so neither
/// the queued copy ("will be sent once…") nor the generic failed copy
/// ("couldn't be sent or saved" — implies retry might work) may show.
/// Any other failure keeps the pre-#97 failed state.
void main() {
  const draft = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'It broke',
    correlationKey: 'key-1',
  );

  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: ShellLocalizations.localizationsDelegates,
    supportedLocales: ShellLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  group('CrashReportPrompt rejected outcome (#97)', () {
    testWidgets('a FeedbackPermanentSubmissionException renders the '
        'rejected state, not failed or queued', (tester) async {
      await tester.pumpWidget(
        host(
          CrashReportPrompt(
            report: draft,
            onSubmit: (_) async =>
                throw const FeedbackPermanentSubmissionException(
                  'rejected',
                  statusCode: 403,
                ),
            onDiscard: () {},
          ),
        ),
      );

      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(CrashReportPrompt.submissionRejectedKey),
        findsOneWidget,
      );
      expect(find.byKey(CrashReportPrompt.submissionFailedKey), findsNothing);
      expect(find.byKey(CrashReportPrompt.queuedConfirmationKey), findsNothing);
    });

    testWidgets('a permanent rejection with no statusCode (client-side '
        'validation — nothing reached the server) renders failed, not '
        'the server-attribution rejected copy', (tester) async {
      await tester.pumpWidget(
        host(
          CrashReportPrompt(
            report: draft,
            onSubmit: (_) async =>
                throw const FeedbackPermanentSubmissionException(
                  'invalid report',
                ),
            onDiscard: () {},
          ),
        ),
      );

      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(CrashReportPrompt.submissionFailedKey), findsOneWidget);
      expect(find.byKey(CrashReportPrompt.submissionRejectedKey), findsNothing);
    });

    testWidgets('any other failure keeps the generic failed state', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          CrashReportPrompt(
            report: draft,
            onSubmit: (_) async =>
                throw const FeedbackPersistenceException('disk full'),
            onDiscard: () {},
          ),
        ),
      );

      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(CrashReportPrompt.submissionFailedKey), findsOneWidget);
      expect(find.byKey(CrashReportPrompt.submissionRejectedKey), findsNothing);
    });
  });

  group('FeedbackReviewScreen rejected outcome (#97)', () {
    testWidgets('a FeedbackPermanentSubmissionException renders the '
        'rejected state as terminal', (tester) async {
      await tester.pumpWidget(
        host(
          FeedbackReviewScreen(
            preview: FeedbackReportPreview.fromReport(draft),
            onSubmit: (_) async =>
                throw const FeedbackPermanentSubmissionException(
                  'rejected',
                  statusCode: 400,
                ),
            onCancel: () {},
            onClose: () {},
          ),
        ),
      );

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(FeedbackReviewScreen.submissionRejectedKey),
        findsOneWidget,
      );
      expect(
        find.byKey(FeedbackReviewScreen.submissionFailedKey),
        findsNothing,
      );
      // Terminal: the review back affordance is gone, only close remains.
      expect(find.byKey(FeedbackReviewScreen.backButtonKey), findsNothing);
      expect(find.byKey(FeedbackReviewScreen.closeButtonKey), findsOneWidget);
    });
  });
}
