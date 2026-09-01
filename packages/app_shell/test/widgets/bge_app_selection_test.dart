import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/stub_feedback_service.dart';
import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

void main() {
  late _MockAppBootstrapCubit cubit;
  late List<String> copied;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    // A state that renders real prose. The splash screen the default state
    // routes to has no text at all, so there would be nothing to select.
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapFailed(
        error: 'boom',
        attemptCount: 1,
        canOfferReset: false,
      ),
    );
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

  /// All four themes, not just `theme`.
  ///
  /// `BgeApp` asserts they agree on `platform`, because the selection gate
  /// reads whichever one `MaterialApp` resolves — overriding one and leaving
  /// the rest on the host platform is exactly the mismatch that would flip
  /// the region mid-session on an OS appearance change.
  Future<void> pumpApp(WidgetTester tester, TargetPlatform platform) async {
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        theme: BgeTheme.light().copyWith(platform: platform),
        darkTheme: BgeTheme.dark().copyWith(platform: platform),
        highContrastTheme: BgeTheme.highContrastLight().copyWith(
          platform: platform,
        ),
        highContrastDarkTheme: BgeTheme.highContrastDark().copyWith(
          platform: platform,
        ),
        themeMode: ThemeMode.light,
      ),
    );
    // This pump is load-bearing: `pumpWidget` is frame one, and the region
    // deliberately does not mount until frame two. See `BgeApp._selectable`.
    await tester.pump();
  }

  /// The first non-trivial run of text on screen.
  Finder someProse() {
    final candidates = find.byWidgetPredicate(
      (w) => w is Text && (w.data?.length ?? 0) > 8,
    );
    expect(
      candidates,
      findsWidgets,
      reason: 'the test needs some text to drag across',
    );
    return candidates.first;
  }

  group('BgeApp text selection (#322)', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      testWidgets('$platform installs the selection region', (tester) async {
        await pumpApp(tester, platform);

        expect(find.byType(SelectionArea), findsOneWidget);
      });
    }

    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      testWidgets('$platform does not', (tester) async {
        await pumpApp(tester, platform);

        expect(find.byType(SelectionArea), findsNothing);
      });
    }

    testWidgets('a drag selects, and the copy shortcut lifts the text', (
      tester,
    ) async {
      await pumpApp(tester, TargetPlatform.macOS);

      final prose = someProse();
      final expected = tester.widget<Text>(prose).data!;
      final box = tester.getRect(prose);
      final drag = await tester.startGesture(
        Offset(box.left + 1, box.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveTo(Offset(box.right - 1, box.center.dy));
      await tester.pump();
      await drag.up();
      await tester.pump();

      // Control, not Meta, and deliberately: `WidgetsApp`'s default
      // shortcuts are built from `defaultTargetPlatform`, which flutter_test
      // pins to android — whereas the region is gated on `Theme.platform`.
      // The two are independent by design, and this line is where that shows.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // A substring rather than equality, deliberately. `someProse()` takes
      // whatever Text the screen builds first, and the drag runs along one
      // horizontal line — reword that copy so it wraps and an equality
      // assertion fails with a clipboard mismatch that looks like a
      // selection bug. What this test is actually for is that a drag
      // selects and the shortcut lifts it.
      expect(copied, hasLength(1));
      expect(copied.single, isNotEmpty);
      expect(
        expected,
        contains(copied.single),
        reason:
            'the clipboard should hold part of the text that was dragged '
            'across, but held "${copied.single}"',
      );
    });

    testWidgets('waits a frame before mounting — the web load-crash fix', (
      tester,
    ) async {
      await tester.pumpWidget(
        BgeApp(
          bootstrapCubit: cubit,
          theme: BgeTheme.light().copyWith(platform: TargetPlatform.macOS),
          darkTheme: BgeTheme.dark().copyWith(platform: TargetPlatform.macOS),
          highContrastTheme: BgeTheme.highContrastLight().copyWith(
            platform: TargetPlatform.macOS,
          ),
          highContrastDarkTheme: BgeTheme.highContrastDark().copyWith(
            platform: TargetPlatform.macOS,
          ),
          themeMode: ThemeMode.light,
        ),
      );

      // `pumpWidget` *is* frame one, and the region is absent in it on
      // purpose. Mounting there registers a focus node mid-build, and on web
      // that synchronously re-enters focus traversal, which reads
      // FocusNode.rect before layout and asserts. Deleting the deferral makes
      // the browser app crash on every load, before any interaction.
      expect(find.byType(SelectionArea), findsNothing);

      // Frame two: the post-frame callback has run.
      await tester.pump();
      expect(find.byType(SelectionArea), findsOneWidget);
    });

    testWidgets('themes that disagree on platform are rejected in debug', (
      tester,
    ) async {
      // Without this the disagreement is silent until an OS appearance
      // change resolves the other theme, flips the gate, and remounts the
      // router subtree — losing the Navigator stack and any typed input.
      await tester.pumpWidget(
        BgeApp(
          bootstrapCubit: cubit,
          theme: BgeTheme.light().copyWith(platform: TargetPlatform.macOS),
          darkTheme: BgeTheme.dark().copyWith(platform: TargetPlatform.android),
        ),
      );

      expect(
        tester.takeException(),
        isA<AssertionError>().having(
          (e) => e.message.toString(),
          'message',
          contains('disagree on ThemeData.platform'),
        ),
      );
    });

    testWidgets('the region sits under an Overlay, so nothing throws on '
        'the first frame', (tester) async {
      // The regression this guards: `SelectableRegionState.build` asserts
      // `debugCheckHasOverlay`, and the builder slot sits above the router's
      // Navigator. A bare `SelectionArea` there throws on frame one.
      await pumpApp(tester, TargetPlatform.macOS);

      expect(tester.takeException(), isNull);
      expect(
        find.ancestor(
          of: find.byType(SelectionArea),
          matching: find.byType(Overlay),
        ),
        findsWidgets,
      );
    });
  });

  /// The crash overlay is a *sibling* of the selectable content, and both
  /// mount Overlays into the same builder slot. These pin that the region
  /// does not disturb the flow the slot's existing comment warns about: a
  /// prompt whose comment field cannot focus re-summons itself and becomes
  /// undismissable.
  group('BgeApp crash flow with the selection region active (#322)', () {
    setUp(ShellObservability.initialize);
    tearDown(() async => ShellObservability.reset());

    UncaughtErrorRecord record() => UncaughtErrorRecord.capture(
      StateError('bad state'),
      StackTrace.fromString('#0 main (file.dart:1)'),
    );

    Future<FeedbackUncaughtErrorReporter> pumpWithCrash(
      WidgetTester tester,
    ) async {
      final bootstrap = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(),
        hydratedStorageInitializer: (_) async {},
      );
      addTearDown(bootstrap.close);
      final reporter = FeedbackUncaughtErrorReporter(
        service: StubFeedbackService(),
      );
      await tester.pumpWidget(
        BgeApp(
          bootstrapCubit: bootstrap,
          feedbackReporter: reporter,
          theme: BgeTheme.light().copyWith(platform: TargetPlatform.macOS),
          darkTheme: BgeTheme.dark().copyWith(platform: TargetPlatform.macOS),
          highContrastTheme: BgeTheme.highContrastLight().copyWith(
            platform: TargetPlatform.macOS,
          ),
          highContrastDarkTheme: BgeTheme.highContrastDark().copyWith(
            platform: TargetPlatform.macOS,
          ),
          themeMode: ThemeMode.light,
        ),
      );
      await tester.pump(); // frame two — the selection region mounts
      reporter.report(record());
      await tester.pump();
      return reporter;
    }

    testWidgets('the prompt still mounts, and the region is still there', (
      tester,
    ) async {
      await pumpWithCrash(tester);

      expect(find.byType(CrashReportPrompt), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the comment field still focuses and accepts text', (
      tester,
    ) async {
      await pumpWithCrash(tester);

      await tester.tap(find.byKey(CrashReportPrompt.commentFieldKey));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(CrashReportPrompt.commentFieldKey),
        'still typeable',
      );
      await tester.pump();

      expect(find.text('still typeable'), findsOneWidget);
    });

    testWidgets('discard still clears the draft — the prompt is dismissible', (
      tester,
    ) async {
      final reporter = await pumpWithCrash(tester);

      await tester.tap(find.byKey(CrashReportPrompt.discardButtonKey));
      await tester.pump();

      expect(find.byType(CrashReportPrompt), findsNothing);
      expect(reporter.pendingCrashReport.value, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the review surface opens outside the region, which is why '
        'it keeps its own opt-in', (tester) async {
      await pumpWithCrash(tester);

      await tester.tap(find.byKey(CrashReportPrompt.reviewButtonKey));
      await tester.pump();

      expect(find.byType(FeedbackReviewScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The substance of #322's third decision. The review surface is a
      // *sibling* of the selectable content in the crash Stack, not a
      // descendant of the region — so the region cannot make its stack trace
      // selectable, and the `SelectableText` there is load-bearing rather
      // than redundant. Delete this and someone will "simplify" that widget
      // away.
      expect(
        find.ancestor(
          of: find.byType(FeedbackReviewScreen),
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
      );
    });
  });
}
