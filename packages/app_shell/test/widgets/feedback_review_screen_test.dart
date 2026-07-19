import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// `FeedbackReviewScreen` (issue #76) — the full review & redaction
/// surface. It is presentation-only and model-driven: redaction toggles
/// run through `FeedbackReportPreview`, displayed values come from
/// `displayJson()`, and the submitted payload from `toSubmittableReport()`.
///
/// `stackTrace` and `breadcrumbs` are shown read-only (decision on #76:
/// the model deliberately excludes them from the redactable set). Strings
/// come from `ShellLocalizations`; tests find affordances by stable [Key]s
/// so they hold across locales.
void main() {
  FeedbackReport buildReport() => FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.high,
    title: 'StateError',
    message: 'StateError: bad state',
    stackTrace: '#0 main (file.dart:1)',
    appVersion: '0.4.1',
    platform: 'macos',
    locale: 'en-US',
    deviceInfo: const {'model': 'MacBookPro', 'osVersion': '14.5'},
    correlationKey: 'key-1',
    breadcrumbs: [
      Breadcrumb(
        timestamp: DateTime.utc(2026, 1, 1),
        level: BgeLogLevel.info,
        loggerName: 'bge.test.harness',
        message: 'opened the add-game screen',
      ),
    ],
  );

  Future<void> pumpReview(
    WidgetTester tester, {
    FeedbackReportPreview? preview,
    Future<FeedbackSubmitResult> Function(FeedbackReport)? onSubmit,
    VoidCallback? onCancel,
    VoidCallback? onClose,
  }) async {
    // The review surface is a scrolling form. In the default 800x600 test
    // viewport the lower rows (environment/device toggles and the
    // diagnostics sections) fall outside the lazily-built ListView cache
    // extent, so they are never realized and can't be found or tapped.
    // Give the test a tall viewport so every row is on-screen; reset after.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: ShellLocalizations.localizationsDelegates,
        supportedLocales: ShellLocalizations.supportedLocales,
        home: FeedbackReviewScreen(
          preview: preview ?? FeedbackReportPreview.fromReport(buildReport()),
          onSubmit: onSubmit ?? (_) async => FeedbackSubmitResult.sent,
          onCancel: onCancel ?? () {},
          onClose: onClose ?? () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const redacted = FeedbackReportPreview.redactedMarker;

  group('FeedbackReviewScreen', () {
    testWidgets('renders the message and environment values', (tester) async {
      await pumpReview(tester);

      expect(find.text('StateError: bad state'), findsOneWidget);
      expect(find.text('0.4.1'), findsOneWidget);
      expect(find.text('macos'), findsOneWidget);
      expect(find.text('en-US'), findsOneWidget);
    });

    testWidgets('exposes a redaction toggle per redactable field, but not '
        'for the read-only diagnostics', (tester) async {
      await pumpReview(tester);

      expect(
        find.byKey(FeedbackReviewScreen.redactToggleKey('message')),
        findsOneWidget,
      );
      expect(
        find.byKey(FeedbackReviewScreen.redactToggleKey('platform')),
        findsOneWidget,
      );
      expect(
        find.byKey(FeedbackReviewScreen.redactToggleKey('deviceInfo.model')),
        findsOneWidget,
      );
      // stackTrace / breadcrumbs are view-only — no toggle.
      expect(
        find.byKey(FeedbackReviewScreen.redactToggleKey('stackTrace')),
        findsNothing,
      );
    });

    testWidgets('renders a toggle for every redactable top-level field the '
        'model exposes — driven by the model set, not a hardcoded list', (
      tester,
    ) async {
      await pumpReview(tester);

      final display = FeedbackReportPreview.fromReport(
        buildReport(),
      ).displayJson();
      for (final field in FeedbackReportPreview.redactableTopLevelFields) {
        if (display[field] != null) {
          expect(
            find.byKey(FeedbackReviewScreen.redactToggleKey(field)),
            findsOneWidget,
            reason: 'redactable field "$field" should expose a toggle',
          );
        }
      }
    });

    testWidgets('shows the stack trace under its expandable section', (
      tester,
    ) async {
      await pumpReview(tester);

      await tester.tap(find.byKey(FeedbackReviewScreen.stackTraceSectionKey));
      await tester.pumpAndSettle();

      expect(find.text('#0 main (file.dart:1)'), findsOneWidget);
    });

    testWidgets('shows the breadcrumb trail under its expandable section', (
      tester,
    ) async {
      await pumpReview(tester);

      await tester.tap(find.byKey(FeedbackReviewScreen.breadcrumbsSectionKey));
      await tester.pumpAndSettle();

      expect(find.text('opened the add-game screen'), findsOneWidget);
    });

    testWidgets('redacting a top-level field populates userRedactedFields '
        'and masks the submitted value', (tester) async {
      FeedbackReport? submitted;
      await pumpReview(
        tester,
        onSubmit: (report) async {
          submitted = report;
          return FeedbackSubmitResult.sent;
        },
      );

      await tester.tap(
        find.byKey(FeedbackReviewScreen.redactToggleKey('platform')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(submitted, isNotNull);
      expect(submitted!.userRedactedFields, contains('platform'));
      expect(submitted!.platform, redacted);
      // Untouched fields are unaffected.
      expect(submitted!.appVersion, '0.4.1');
    });

    testWidgets('redacting a deviceInfo dot-path masks that key only', (
      tester,
    ) async {
      FeedbackReport? submitted;
      await pumpReview(
        tester,
        onSubmit: (report) async {
          submitted = report;
          return FeedbackSubmitResult.sent;
        },
      );

      await tester.tap(
        find.byKey(FeedbackReviewScreen.redactToggleKey('deviceInfo.model')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(submitted!.userRedactedFields, contains('deviceInfo.model'));
      expect(submitted!.deviceInfo!['model'], redacted);
      expect(submitted!.deviceInfo!['osVersion'], '14.5');
    });

    testWidgets('toggling a field on then off leaves it unredacted', (
      tester,
    ) async {
      FeedbackReport? submitted;
      await pumpReview(
        tester,
        onSubmit: (report) async {
          submitted = report;
          return FeedbackSubmitResult.sent;
        },
      );

      final toggle = find.byKey(
        FeedbackReviewScreen.redactToggleKey('platform'),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(submitted!.userRedactedFields, isEmpty);
      expect(submitted!.platform, 'macos');
    });

    testWidgets('a sent outcome shows the sent confirmation', (tester) async {
      await pumpReview(tester);

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(FeedbackReviewScreen.sentConfirmationKey),
        findsOneWidget,
      );
    });

    testWidgets('a queued outcome shows the honest saved-for-later state', (
      tester,
    ) async {
      await pumpReview(
        tester,
        onSubmit: (_) async => FeedbackSubmitResult.queued,
      );

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(FeedbackReviewScreen.queuedConfirmationKey),
        findsOneWidget,
      );
    });

    testWidgets('a submission failure shows the failed state', (tester) async {
      await pumpReview(
        tester,
        onSubmit: (_) async =>
            throw const FeedbackSubmissionException('everything failed'),
      );

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(FeedbackReviewScreen.submissionFailedKey),
        findsOneWidget,
      );
    });

    testWidgets('backing out calls onCancel and never submits', (tester) async {
      var cancelled = false;
      var submitCalls = 0;
      await pumpReview(
        tester,
        onSubmit: (_) async {
          submitCalls++;
          return FeedbackSubmitResult.sent;
        },
        onCancel: () => cancelled = true,
      );

      await tester.tap(find.byKey(FeedbackReviewScreen.backButtonKey));
      await tester.pumpAndSettle();

      expect(cancelled, isTrue);
      expect(submitCalls, 0);
    });

    testWidgets('closing after a terminal outcome calls onClose', (
      tester,
    ) async {
      var closed = false;
      await pumpReview(tester, onClose: () => closed = true);

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FeedbackReviewScreen.closeButtonKey));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
    });

    testWidgets('send is a semantic button and redaction toggles carry '
        'toggled state — a11y baseline', (tester) async {
      await pumpReview(tester);

      expect(
        tester.getSemantics(find.byKey(FeedbackReviewScreen.sendButtonKey)),
        isSemantics(isButton: true),
      );
      expect(
        tester.getSemantics(
          find.byKey(FeedbackReviewScreen.redactToggleKey('platform')),
        ),
        isSemantics(hasToggledState: true, isToggled: false),
      );

      // The field label is exposed to assistive tech. `SwitchListTile`
      // merges its title with the value node, so match by substring (the
      // merged label is "Platform <value>"), not exact equality. Loaded via
      // the i18n delegate so the assertion stays locale-agnostic.
      final i18n = await ShellLocalizations.delegate.load(const Locale('en'));
      expect(
        find.bySemanticsLabel(
          RegExp(RegExp.escape(i18n.feedbackReviewFieldPlatform)),
        ),
        findsWidgets,
      );
    });
  });
}
