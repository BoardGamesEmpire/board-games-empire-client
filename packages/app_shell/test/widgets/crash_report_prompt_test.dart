import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// `CrashReportPrompt` (issue #69) — the minimal
/// accessible "ask each time" crash prompt. The full review/redaction
/// surface is #76; this widget is deliberately small: crash summary,
/// optional comment, send/discard, and an **honest outcome** — "sent"
/// vs "saved to send later" (`FeedbackSubmitResult`), because on web
/// "saved" only lasts until reload.
///
/// #76 adds one seam: an optional `onReviewDetails` callback that, when
/// supplied, surfaces a "Review details" affordance and hands the
/// currently-typed comment up. The prompt still owns no review UI.
///
/// The widget is dumb: it takes the pre-built draft (capture-time
/// breadcrumbs — see the reporter tests) and callbacks; shell wiring
/// owns clearing the slots. Strings come from `ShellLocalizations`
/// tests find by stable [Key]s so they hold across locales.
void main() {
  const draft = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'StateError: bad state',
    stackTrace: '#0 main (file.dart:1)',
    title: 'StateError',
    correlationKey: 'key-1',
  );

  Future<void> pumpPrompt(
    WidgetTester tester, {
    Future<FeedbackSubmitResult> Function(FeedbackReport)? onSubmit,
    VoidCallback? onDiscard,
    void Function(String comment)? onReviewDetails,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: ShellLocalizations.localizationsDelegates,
        supportedLocales: ShellLocalizations.supportedLocales,
        home: Scaffold(
          body: CrashReportPrompt(
            report: draft,
            onSubmit: onSubmit ?? (_) async => FeedbackSubmitResult.sent,
            onDiscard: onDiscard ?? () {},
            onReviewDetails: onReviewDetails,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('CrashReportPrompt', () {
    testWidgets('shows the crash summary and the core affordances', (
      tester,
    ) async {
      await pumpPrompt(tester);

      expect(find.textContaining('StateError'), findsWidgets);
      expect(find.byKey(CrashReportPrompt.commentFieldKey), findsOneWidget);
      expect(find.byKey(CrashReportPrompt.sendButtonKey), findsOneWidget);
      expect(find.byKey(CrashReportPrompt.discardButtonKey), findsOneWidget);
    });

    testWidgets('send submits the draft with the typed comment woven in', (
      tester,
    ) async {
      FeedbackReport? submitted;
      await pumpPrompt(
        tester,
        onSubmit: (report) async {
          submitted = report;
          return FeedbackSubmitResult.sent;
        },
      );

      await tester.enterText(
        find.byKey(CrashReportPrompt.commentFieldKey),
        'I was adding a game',
      );
      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(submitted, isNotNull);
      expect(submitted!.message, contains('StateError: bad state'));
      expect(submitted!.message, contains('I was adding a game'));
      expect(submitted!.correlationKey, draft.correlationKey);
    });

    testWidgets('send without a comment submits the draft unchanged', (
      tester,
    ) async {
      FeedbackReport? submitted;
      await pumpPrompt(
        tester,
        onSubmit: (report) async {
          submitted = report;
          return FeedbackSubmitResult.sent;
        },
      );

      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(submitted, draft);
    });

    testWidgets('a sent outcome shows the sent confirmation', (tester) async {
      await pumpPrompt(tester);

      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(CrashReportPrompt.sentConfirmationKey), findsOneWidget);
      expect(find.byKey(CrashReportPrompt.queuedConfirmationKey), findsNothing);
    });

    testWidgets('a queued outcome shows the saved-for-later state — the '
        'honest message when there was no reachable server', (tester) async {
      await pumpPrompt(
        tester,
        onSubmit: (_) async => FeedbackSubmitResult.queued,
      );

      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(CrashReportPrompt.queuedConfirmationKey),
        findsOneWidget,
      );
    });

    testWidgets('a submission failure shows the failed state and keeps '
        'discard available', (tester) async {
      await pumpPrompt(
        tester,
        onSubmit: (_) async =>
            throw const FeedbackPersistenceException('everything failed'),
      );

      await tester.tap(find.byKey(CrashReportPrompt.sendButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(CrashReportPrompt.submissionFailedKey), findsOneWidget);
      expect(find.byKey(CrashReportPrompt.discardButtonKey), findsOneWidget);
    });

    testWidgets('discard calls onDiscard and never submits', (tester) async {
      var discarded = false;
      var submitCalls = 0;
      await pumpPrompt(
        tester,
        onSubmit: (_) async {
          submitCalls++;
          return FeedbackSubmitResult.sent;
        },
        onDiscard: () => discarded = true,
      );

      await tester.tap(find.byKey(CrashReportPrompt.discardButtonKey));
      await tester.pump();

      expect(discarded, isTrue);
      expect(submitCalls, 0);
    });

    testWidgets('the review affordance is hidden when no review handler '
        'is wired — #69-only behavior is unchanged', (tester) async {
      await pumpPrompt(tester);

      expect(find.byKey(CrashReportPrompt.reviewButtonKey), findsNothing);
    });

    testWidgets('review details hands the typed comment up without '
        'submitting (#76 seam)', (tester) async {
      String? handedUp;
      var submitCalls = 0;
      await pumpPrompt(
        tester,
        onSubmit: (_) async {
          submitCalls++;
          return FeedbackSubmitResult.sent;
        },
        onReviewDetails: (comment) => handedUp = comment,
      );

      await tester.enterText(
        find.byKey(CrashReportPrompt.commentFieldKey),
        'crashed on the settings screen',
      );
      await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
      await tester.pump();

      expect(handedUp, 'crashed on the settings screen');
      expect(submitCalls, 0);
    });

    testWidgets('send and discard are semantic buttons; the comment '
        'field label is exposed to assistive tech — a11y baseline', (
      tester,
    ) async {
      await pumpPrompt(tester);

      expect(
        tester.getSemantics(find.byKey(CrashReportPrompt.sendButtonKey)),
        isSemantics(isButton: true),
      );
      expect(
        tester.getSemantics(find.byKey(CrashReportPrompt.discardButtonKey)),
        isSemantics(isButton: true),
      );

      // InputDecoration.labelText is the Material accessible-label
      // mechanism, but WHERE Flutter hangs it in the semantics tree
      // (merged onto the text field's node vs the decorator's own label
      // node) varies by version — so assert the label's *presence* in
      // the tree, not its placement on one node. Loaded via the i18n
      // delegate so the assertion stays locale-agnostic.
      final i18n = await ShellLocalizations.delegate.load(const Locale('en'));
      expect(
        find.bySemanticsLabel(i18n.crashReportPromptCommentLabel),
        findsWidgets,
      );
    });
  });
}
