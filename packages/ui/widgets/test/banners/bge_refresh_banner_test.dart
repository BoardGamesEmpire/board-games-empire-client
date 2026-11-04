import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _failed = 'Households may be out of date.';
const _inProgress = 'Refreshing\u{2026}';
const _retry = 'Try again';
const _retryKey = ValueKey('retry');

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
      expect(
        tester.widget<TextButton>(find.byKey(_retryKey)).onPressed,
        isNull,
      );
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
