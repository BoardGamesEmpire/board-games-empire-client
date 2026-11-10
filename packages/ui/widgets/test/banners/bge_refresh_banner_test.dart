import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _failed = 'Households may be out of date.';
const _inProgress = 'Refreshing\u{2026}';
const _retry = 'Try again';
const ValueKey<String> _retryKey = ValueKey('retry');

Widget _banner({bool refreshing = false, VoidCallback? onRetry, Key? key}) =>
    BgeRefreshBanner(
      key: key,
      failedMessage: _failed,
      inProgressLabel: _inProgress,
      retryLabel: _retry,
      retryKey: _retryKey,
      refreshing: refreshing,
      onRetry: onRetry,
    );

Widget _host(Widget child, {TextScaler textScaler = TextScaler.noScaling}) =>
    MaterialApp(
      theme: BgeTheme.light(),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: app!,
      ),
      home: Scaffold(body: child),
    );

void main() {
  group('BgeRefreshBanner', () {
    testWidgets('warning tone and the failed message at rest', (tester) async {
      await tester.pumpWidget(_host(_banner(onRetry: () {})));

      final banner = tester.widget<BgeInlineBanner>(
        find.byType(BgeInlineBanner),
      );
      expect(banner.tone, BgeBannerTone.warning);
      expect(find.text(_failed), findsOneWidget);
      expect(find.text(_retry), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets('info tone, the in-progress label and a spinner while '
        'refreshing', (tester) async {
      await tester.pumpWidget(_host(_banner(refreshing: true, onRetry: () {})));

      final banner = tester.widget<BgeInlineBanner>(
        find.byType(BgeInlineBanner),
      );
      expect(banner.tone, BgeBannerTone.info);
      // The message and the button's label both say it.
      expect(find.text(_inProgress), findsNWidgets(2));
      expect(find.text(_failed), findsNothing);
      expect(find.text(_retry), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      // Enabled but inert: a disabled button cannot hold focus (#607).
      expect(
        tester.widget<TextButton>(find.byKey(_retryKey)).onPressed,
        isNotNull,
      );
    });

    FocusNode retryFocus(WidgetTester tester) =>
        tester.widget<TextButton>(find.byKey(_retryKey)).focusNode!;

    testWidgets('a focused retry keeps focus through a pass', (tester) async {
      var retries = 0;
      Widget at({required bool refreshing}) =>
          _host(_banner(refreshing: refreshing, onRetry: () => retries++));
      await tester.pumpWidget(at(refreshing: false));

      retryFocus(tester).requestFocus();
      await tester.pump();
      await tester.tap(find.byKey(_retryKey));
      await tester.pumpWidget(at(refreshing: true));

      expect(retryFocus(tester).hasFocus, isTrue);

      await tester.pumpWidget(at(refreshing: false));

      expect(retryFocus(tester).hasFocus, isTrue);
      expect(retries, 1);
    });

    testWidgets('a press while refreshing does nothing', (tester) async {
      var retries = 0;
      await tester.pumpWidget(_host(_banner(onRetry: () => retries++)));
      await tester.tap(find.byKey(_retryKey));
      await tester.pumpWidget(
        _host(_banner(refreshing: true, onRetry: () => retries++)),
      );

      await tester.tap(find.byKey(_retryKey));
      await tester.pump();

      expect(retries, 1);
    });

    testWidgets('holding Enter on a busy retry starts one pass', (
      tester,
    ) async {
      var retries = 0;
      Widget at({required bool refreshing}) =>
          _host(_banner(refreshing: refreshing, onRetry: () => retries++));
      await tester.pumpWidget(at(refreshing: false));
      retryFocus(tester).requestFocus();
      await tester.pump();

      // The key goes down at rest: pass 1.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(retries, 1);

      // Held through the pass.
      await tester.pumpWidget(at(refreshing: true));
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      }
      expect(retries, 1);

      // The pass ends with the key still held: its repeats are not a press.
      await tester.pumpWidget(at(refreshing: false));
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      }
      expect(retries, 1);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(retryFocus(tester).hasFocus, isTrue);

      // A fresh press is the retry again.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(retries, 2);
    });

    testWidgets('the retry keeps one semantics node through a pass', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      Widget at({required bool refreshing}) =>
          _host(_banner(refreshing: refreshing, onRetry: () {}));
      await tester.pumpWidget(at(refreshing: false));
      final rest = tester.getSemantics(find.byKey(_retryKey)).id;

      await tester.pumpWidget(at(refreshing: true));
      expect(tester.getSemantics(find.byKey(_retryKey)).id, rest);

      await tester.pumpWidget(at(refreshing: false));
      expect(tester.getSemantics(find.byKey(_retryKey)).id, rest);
      handle.dispose();
    });

    testWidgets('on iOS the busy retry offers no focus action', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_banner(refreshing: true, onRetry: () {})));
      retryFocus(tester).requestFocus();
      await tester.pump();

      expect(
        tester.getSemantics(find.byKey(_retryKey)),
        matchesSemantics(
          label: _inProgress,
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasEnabledState: true,
        ),
      );
      handle.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('while refreshing it reads as in progress, not as an '
        'action', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_banner(refreshing: true, onRetry: () {})));

      // Never focused: focusable, with a focus action and no tap.
      expect(
        tester.getSemantics(find.byKey(_retryKey)),
        matchesSemantics(
          label: _inProgress,
          isButton: true,
          isFocusable: true,
          hasEnabledState: true,
          hasFocusAction: true,
        ),
      );

      retryFocus(tester).requestFocus();
      await tester.pump();

      expect(
        tester.getSemantics(find.byKey(_retryKey)),
        matchesSemantics(
          label: _inProgress,
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasEnabledState: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('at rest the retry reads as an enabled button', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_banner(onRetry: () {})));
      retryFocus(tester).requestFocus();
      await tester.pump();

      expect(
        tester.getSemantics(find.byKey(_retryKey)),
        matchesSemantics(
          label: _retry,
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('no action without onRetry', (tester) async {
      await tester.pumpWidget(_host(_banner()));

      expect(find.text(_failed), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byKey(_retryKey), findsNothing);
    });

    testWidgets('the retry carries retryKey', (tester) async {
      var retries = 0;
      await tester.pumpWidget(_host(_banner(onRetry: () => retries++)));

      expect(
        find.descendant(of: find.byKey(_retryKey), matching: find.text(_retry)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(_retryKey));
      expect(retries, 1);
    });

    testWidgets('does not reveal itself', (tester) async {
      useViewSize(tester, const Size(320, 480));
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            controller: controller,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 1200),
                _banner(onRetry: () {}),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.offset, 0);
    });

    for (final width in [320.0, 360.0, 412.0]) {
      testWidgets('fits $width dp at 200% text, at rest and refreshing', (
        tester,
      ) async {
        // Before #452 the message and the retry shared a row, and at 200% the
        // retry ran off the window's right edge. That edge is what shows
        // whether the banner made room for it.
        useViewSize(tester, Size(width, 800));
        const scaler = TextScaler.linear(BgeTextScale.maxScaleFactor);

        for (final refreshing in [false, true]) {
          await tester.pumpWidget(
            _host(
              _banner(refreshing: refreshing, onRetry: () {}),
              textScaler: scaler,
            ),
          );
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byKey(_retryKey)).right,
            lessThanOrEqualTo(width),
          );
        }
      });
    }
  });
}
