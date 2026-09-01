import 'package:app_shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';
import 'package:ui_tokens/ui_tokens.dart';

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
    clientRequestId: 'key-1',
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
    // The review surface is a SliverList through BgePage.slivers, so rows
    // below the fold are not built at all — they can be neither found nor
    // tapped. Give the test a tall viewport; reset after.
    //
    // The reason changed with the sliver migration (a612dbc) even though the
    // tall viewport did not: before it, the rows built eagerly and only the
    // tap was blocked, because `tester.tap` needs an on-screen target. Now
    // `find` cannot reach them either, which is a stricter requirement met by
    // the same fix.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        // The real theme, so a measure assertion tests the wiring rather
        // than `BgeTokens.of`'s no-theme fallback agreeing with itself.
        theme: BgeTheme.light(),
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

  group('FeedbackReviewScreen copy affordance (#322)', () {
    late List<String> copied;

    setUp(() {
      copied = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('lifts the whole reviewed report, not a dragged fragment', (
      tester,
    ) async {
      await pumpReview(tester);

      await tester.tap(find.byKey(FeedbackReviewScreen.copyButtonKey));
      await tester.pumpAndSettle();

      expect(copied, hasLength(1));
      // The fields the user is looking at, in a form that survives a paste
      // into a bug report — which is the whole point of #322 on a platform
      // with no selection region.
      expect(copied.single, contains('StateError: bad state'));
      expect(copied.single, contains('#0 main (file.dart:1)'));
      expect(copied.single, contains('0.4.1'));
    });

    testWidgets('honours redaction — a redacted field is not copied', (
      tester,
    ) async {
      await pumpReview(tester);

      await tester.tap(
        find.byKey(FeedbackReviewScreen.redactToggleKey('message')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(FeedbackReviewScreen.copyButtonKey));
      await tester.pumpAndSettle();

      // The #34 privacy contract reaches the clipboard too. Copying what is
      // displayed rather than the submittable report is what makes this
      // hold; if the copy ever switches to toSubmittableReport() this fails.
      expect(copied.single, isNot(contains('StateError: bad state')));
      expect(copied.single, contains(redacted));
    });

    testWidgets('confirms the copy, so it is not a silent no-op', (
      tester,
    ) async {
      await pumpReview(tester);

      await tester.tap(find.byKey(FeedbackReviewScreen.copyButtonKey));
      await tester.pump();

      expect(find.byType(SnackBar), findsOneWidget);
    });

    // The two classifications that are neither obvious nor symmetrical, and
    // the reason `_copyable` is not simply `!_terminal`. A refactor that
    // reuses `_terminal` for the gate passes every other test in this group
    // while silently removing the copy from `rejected`.
    testWidgets('repeated taps do not stack confirmations', (tester) async {
      await pumpReview(tester);

      // Natural behaviour: `Clipboard.setData` is an async platform
      // round-trip, so a user taps again when the first tap looks inert.
      // Queued SnackBars would replay the same banner for ~12 seconds.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(FeedbackReviewScreen.copyButtonKey));
        await tester.pump();
      }

      expect(find.byType(SnackBar), findsOneWidget);

      // Necessary but nowhere near sufficient, and the gap is the whole point
      // of this test: `ScaffoldMessenger` materializes only the front of its
      // queue, so `findsOneWidget` holds identically whether one bar is
      // showing or three are stacked behind it. Measured on 3.47.1: a single
      // confirmation leaves the screen clear by ~6s, while three queued ones
      // were still replaying past 16s. Walking the clock past one bar's
      // lifetime is the only thing that tells those two apart.
      //
      // Stepped rather than one `pump(seconds: 8)`, and not `pumpAndSettle`.
      // A single jump fires the dismiss timer but leaves the exit animation
      // with no frames to run in, so the bar is still mounted mid-reverse and
      // this reads as a failure whether or not the bug is present.
      // `pumpAndSettle` fails the other way: it would patiently drain all
      // three queued bars and then report a clear screen, passing on exactly
      // the state this test exists to catch.
      for (var second = 0; second < 8; second++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a clipboard failure says so instead of failing silently', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              throw PlatformException(code: 'no-clipboard');
            }
            return null;
          });
      await pumpReview(tester);

      await tester.tap(find.byKey(FeedbackReviewScreen.copyButtonKey));
      await tester.pumpAndSettle();

      expect(copied, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget);
      // Swallowed rather than rethrown on purpose: an escaping error would
      // reach PlatformDispatcher.onError, which the global hooks turn into a
      // crash report — a failed copy must not summon a crash prompt on top
      // of the crash being reported.
      expect(tester.takeException(), isNull);
    });

    testWidgets('is gone once the report is queued to send later', (
      tester,
    ) async {
      await pumpReview(
        tester,
        onSubmit: (_) async => FeedbackSubmitResult.queued,
      );

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // Saved on the device and it will go out on its own — not lost, so
      // nothing to salvage.
      expect(
        find.byKey(FeedbackReviewScreen.queuedConfirmationKey),
        findsOneWidget,
      );
      expect(find.byKey(FeedbackReviewScreen.copyButtonKey), findsNothing);
    });

    testWidgets('survives a permanent rejection, which is not queued', (
      tester,
    ) async {
      await pumpReview(
        tester,
        onSubmit: (_) async => throw const FeedbackPermanentSubmissionException(
          'server said no',
          statusCode: 422,
        ),
      );

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(FeedbackReviewScreen.submissionRejectedKey),
        findsOneWidget,
      );

      // The server refused it and nothing was saved. Close is the only other
      // affordance, and it drops the report.
      expect(find.byKey(FeedbackReviewScreen.copyButtonKey), findsOneWidget);
      await tester.tap(find.byKey(FeedbackReviewScreen.copyButtonKey));
      await tester.pumpAndSettle();

      expect(copied.single, contains('StateError: bad state'));
    });

    testWidgets('is gone once the report has actually been sent', (
      tester,
    ) async {
      await pumpReview(tester);

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();

      // Delivered — it is out of the user's hands, so there is nothing left
      // to salvage.
      expect(
        find.byKey(FeedbackReviewScreen.sentConfirmationKey),
        findsOneWidget,
      );
      expect(find.byKey(FeedbackReviewScreen.copyButtonKey), findsNothing);
    });

    testWidgets('survives a failed submission — the one state where the '
        'report is about to be lost', (tester) async {
      await pumpReview(
        tester,
        onSubmit: (_) async =>
            throw const FeedbackPersistenceException('everything failed'),
      );

      await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(FeedbackReviewScreen.submissionFailedKey),
        findsOneWidget,
      );

      // Not sent and not queued: the only other affordance here is Close,
      // which drops the draft. Taking the copy away on this state would
      // strand the user exactly when the report became unrecoverable.
      expect(find.byKey(FeedbackReviewScreen.copyButtonKey), findsOneWidget);
      await tester.tap(find.byKey(FeedbackReviewScreen.copyButtonKey));
      await tester.pumpAndSettle();

      expect(copied.single, contains('StateError: bad state'));
    });
  });

  group('FeedbackReviewScreen layout', () {
    testWidgets('caps the content column at the form measure', (tester) async {
      await pumpReview(tester);

      // Step one of this flow (compose) is a BgePage capped at this measure.
      // Built on a raw Scaffold, this step ran full-bleed, so the column
      // visibly jumped width halfway through the flow on any desktop window.
      // The harness viewport is 1200 wide, comfortably past the cap.
      // Measured on a row: the list is a sliver and has no width of its own,
      // and a row is what the measure governs.
      expect(
        tester
            .getSize(
              find.byKey(FeedbackReviewScreen.redactToggleKey('platform')),
            )
            .width,
        BgeTokens.standard.contentMaxWidth,
      );
    });

    testWidgets('keeps the send button pinned while the report scrolls', (
      tester,
    ) async {
      await pumpReview(tester);
      // Shorten the viewport after pumping — the harness sets a tall one so
      // every row is tappable, but this case needs the report to overflow.
      tester.view.physicalSize = const Size(1200, 500);
      await tester.pumpAndSettle();

      final before = tester
          .getTopLeft(find.byKey(FeedbackReviewScreen.sendButtonKey))
          .dy;
      // Scoped to the page's own scroll view: an unscoped byType finder
      // throws the moment a second scrollable appears anywhere in the tree.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
      await tester.pump();

      // The send button is the page footer, not the last row: on a long
      // report it must not scroll out of reach.
      expect(
        tester.getTopLeft(find.byKey(FeedbackReviewScreen.sendButtonKey)).dy,
        before,
      );
    });
  });

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

      final display = FeedbackReportPreview.fromReport(buildReport())
          .displayJson();
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
            throw const FeedbackPersistenceException('everything failed'),
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

      // The key now sits on `BgeSubmitButton`, which renders the FilledButton;
      // reading semantics off the wrapper returns the enclosing route node.
      expect(
        tester.getSemantics(
          find.descendant(
            of: find.byKey(FeedbackReviewScreen.sendButtonKey),
            matching: find.byType(FilledButton),
          ),
        ),
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
