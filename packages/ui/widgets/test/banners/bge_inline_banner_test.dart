import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? BgeTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  group('BgeInlineBanner tone', () {
    testWidgets('each tone pairs a distinct icon with its color', (
      tester,
    ) async {
      // The icon is the point: color alone would be unreadable for a
      // color-vision-deficient user, and this is the component most likely to
      // be carrying information they need.
      const expected = {
        BgeBannerTone.error: Icons.error_outline,
        BgeBannerTone.info: Icons.info_outline,
        BgeBannerTone.warning: Icons.warning_amber_outlined,
        BgeBannerTone.success: Icons.check_circle_outline,
      };

      for (final entry in expected.entries) {
        await tester.pumpWidget(
          _host(BgeInlineBanner(tone: entry.key, message: 'm')),
        );
        expect(
          find.byIcon(entry.value),
          findsOneWidget,
          reason: '${entry.key} must carry its own icon',
        );
      }
    });

    testWidgets('error and warning draw from different color roles', (
      tester,
    ) async {
      // Warning must not read as failure. The palette holds ember and crimson
      // ~54° apart in hue specifically so this distinction survives.
      final scheme = BgeTheme.light().colorScheme;

      await tester.pumpWidget(
        _host(const BgeInlineBanner(tone: BgeBannerTone.error, message: 'm')),
      );
      final errorBox = tester.widget<Container>(find.byType(Container));
      final errorColor = (errorBox.decoration! as BoxDecoration).color;

      await tester.pumpWidget(
        _host(const BgeInlineBanner(tone: BgeBannerTone.warning, message: 'm')),
      );
      final warnBox = tester.widget<Container>(find.byType(Container));
      final warnColor = (warnBox.decoration! as BoxDecoration).color;

      expect(errorColor, scheme.errorContainer);
      expect(warnColor, scheme.tertiaryContainer);
      expect(errorColor, isNot(warnColor));
    });
  });

  group('BgeInlineBanner semantics', () {
    testWidgets('announces on appearance and reads as one node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const BgeInlineBanner(
            tone: BgeBannerTone.error,
            title: 'Could not add server',
            message: 'That URL is not a BGE server.',
          ),
        ),
      );

      // One traversal stop carrying both strings — not a decorative icon,
      // then a title, then a sentence.
      //
      // Found via the message text, not `byType(BgeInlineBanner)`: the merge
      // boundary sits on the icon+text subtree rather than the banner root, so
      // that an `action` can keep its own semantics. Querying the root returns
      // the bare container node with no label.
      final node = tester.getSemantics(
        find.text('That URL is not a BGE server.'),
      );
      expect(node.label, contains('Could not add server'));
      expect(node.label, contains('That URL is not a BGE server.'));
      expect(
        node.flagsCollection.isLiveRegion,
        isTrue,
        reason: 'the banner must announce itself rather than wait to be found',
      );
      handle.dispose();
    });

    testWidgets('an action stays independently focusable and activatable', (
      tester,
    ) async {
      // Regression: merging the whole banner — action included — into one node
      // strips the button's own semantics. A screen-reader user then gets one
      // long unactionable string where there was an error AND a way out of it.
      final handle = tester.ensureSemantics();
      var retried = 0;
      await tester.pumpWidget(
        _host(
          BgeInlineBanner(
            tone: BgeBannerTone.error,
            message: 'Could not reach the server.',
            action: TextButton(
              onPressed: () => retried++,
              child: const Text('Retry'),
            ),
          ),
        ),
      );

      final button = tester.getSemantics(find.text('Retry'));
      expect(button.label, 'Retry');
      expect(
        button.flagsCollection.isButton,
        isTrue,
        reason: 'the action must survive as its own semantics node',
      );
      expect(
        button.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'a merged-away button is no longer activatable',
      );

      await tester.tap(find.text('Retry'));
      expect(retried, 1);

      // The message still reads as one merged stop, without the action in it.
      final banner = tester.getSemantics(
        find.text('Could not reach the server.'),
      );
      expect(banner.label, isNot(contains('Retry')));
      handle.dispose();
    });

    testWidgets('can opt out of announcing', (tester) async {
      final handle = tester.ensureSemantics();

      // Asserted against the MESSAGE node, not the banner root. The root
      // carries no live region in either case, so querying it would pass this
      // test even if `announce` were ignored entirely.
      await tester.pumpWidget(
        _host(const BgeInlineBanner(message: 'context, not news')),
      );
      expect(
        tester
            .getSemantics(find.text('context, not news'))
            .flagsCollection
            .isLiveRegion,
        isTrue,
        reason: 'sanity: announcing is the default',
      );

      await tester.pumpWidget(
        _host(
          const BgeInlineBanner(message: 'context, not news', announce: false),
        ),
      );
      expect(
        tester
            .getSemantics(find.text('context, not news'))
            .flagsCollection
            .isLiveRegion,
        isFalse,
      );
      handle.dispose();
    });
  });

  group('BgeInlineBanner layout', () {
    testWidgets('wraps long messages instead of overflowing at 2.0 scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          // Scrollable, because that is how banners are actually hosted —
          // inside a BgePage. At 2.0 text scale this banner is taller than a
          // 640px viewport, and pinning it in a non-scrolling body would be
          // testing the host's mistake rather than the banner's behaviour.
          child: _host(
            const SingleChildScrollView(
              child: SizedBox(
                width: 320,
                child: BgeInlineBanner(
                  tone: BgeBannerTone.error,
                  title: 'Could not reach the server',
                  message:
                      'The server did not respond in time. Check the address '
                      'and your connection, then try again.',
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
