import 'package:app_shell/l10n/shell_localizations.dart';
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
            throw const FeedbackSubmissionException('everything failed'),
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

    testWidgets('send and discard are semantic buttons; the comment '
        'field label is exposed to assistive tech — a11y baseline', (
      tester,
    ) async {
      await pumpPrompt(tester);

      expect(
        tester.getSemantics(find.byKey(CrashReportPrompt.sendButtonKey)),
        containsSemantics(isButton: true),
      );
      expect(
        tester.getSemantics(find.byKey(CrashReportPrompt.discardButtonKey)),
        containsSemantics(isButton: true),
      );

      // InputDecoration.labelText is the Material accessible-label
      // mechanism, but WHERE Flutter hangs it in the semantics tree
      // (merged onto the text field's node vs the decorator's own label
      // node) varies by version — so assert the label's *presence* in
      // the tree, not its placement on one node. Loaded via the l10n
      // delegate so the assertion stays locale-agnostic.
      final l10n = await ShellLocalizations.delegate.load(const Locale('en'));
      expect(
        find.bySemanticsLabel(l10n.crashReportPromptCommentLabel),
        findsWidgets,
      );
    });
  });
}
