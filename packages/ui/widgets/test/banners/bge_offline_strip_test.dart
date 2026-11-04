import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _offline = "You're offline. Changes will sync when you reconnect.";
const _back = 'Back online';

Widget _strip(BgeOfflineStripState state, {Key? key}) => BgeOfflineStrip(
  key: key,
  state: state,
  offlineMessage: _offline,
  backOnlineMessage: _back,
);

Widget _host(
  Widget child, {
  double width = 400,
  TextScaler textScaler = TextScaler.noScaling,
  EdgeInsets padding = EdgeInsets.zero,
  bool disableAnimations = false,
}) => MaterialApp(
  theme: BgeTheme.light(),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: textScaler,
      padding: padding,
      viewPadding: padding,
      disableAnimations: disableAnimations,
    ),
    child: app!,
  ),
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(width: width, child: child),
  ),
);

void main() {
  group('BgeOfflineStrip', () {
    testWidgets('hidden draws nothing and leaves no live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_strip(BgeOfflineStripState.hidden)));

      expect(find.byType(Icon), findsNothing);
      expect(find.byType(Text), findsNothing);
      expect(tester.getSize(find.byType(BgeOfflineStrip)).height, 0);
      expect(
        tester.semantics.simulatedAccessibilityTraversal(),
        isEmpty,
        reason: 'no node at all while hidden',
      );
      handle.dispose();
    });

    testWidgets('hidden takes no height under a top inset', (tester) async {
      await tester.pumpWidget(
        _host(
          _strip(BgeOfflineStripState.hidden),
          padding: const EdgeInsets.only(top: 24),
        ),
      );

      expect(tester.getSize(find.byType(BgeOfflineStrip)).height, 0);
    });

    testWidgets('offline pads the top inset above its content', (tester) async {
      await tester.pumpWidget(
        _host(
          _strip(BgeOfflineStripState.offline),
          padding: const EdgeInsets.only(top: 24),
        ),
      );
      final padded = tester.getSize(find.byType(BgeOfflineStrip)).height;
      final textTop = tester.getTopLeft(find.text(_offline)).dy;

      await tester.pumpWidget(_host(_strip(BgeOfflineStripState.offline)));
      final flush = tester.getSize(find.byType(BgeOfflineStrip)).height;

      expect(padded - flush, 24);
      expect(textTop, greaterThanOrEqualTo(24));
    });

    testWidgets('offline: icon, message, one live-region node', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_strip(BgeOfflineStripState.offline)));

      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(find.text(_offline), findsOneWidget);
      expect(
        tester.getSemantics(find.text(_offline)),
        matchesSemantics(label: _offline, isLiveRegion: true),
      );
      final scheme = BgeTheme.light().colorScheme;
      final text = tester.widget<Text>(find.text(_offline));
      expect(text.style!.color, scheme.onSurfaceVariant);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.cloud_off_outlined)).color,
        scheme.onSurfaceVariant,
      );
      handle.dispose();
    });

    testWidgets('backOnline: the synced icon, the message, one live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_strip(BgeOfflineStripState.backOnline)));

      final theme = BgeTheme.light();
      expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.cloud_done_outlined)).color,
        theme.colorScheme.secondary,
      );
      // The text stays in onSurfaceVariant: secondary falls short of 7:1 as
      // text in the high-contrast schemes.
      expect(
        tester.widget<Text>(find.text(_back)).style!.color,
        theme.colorScheme.onSurfaceVariant,
      );
      expect(
        tester.getSemantics(find.text(_back)),
        matchesSemantics(label: _back, isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('offline to backOnline keeps the same element and changes the '
        'label', (tester) async {
      final handle = tester.ensureSemantics();
      const key = ValueKey('strip');
      await tester.pumpWidget(
        _host(_strip(BgeOfflineStripState.offline, key: key)),
      );
      final before = tester.element(
        find.descendant(
          of: find.byType(BgeOfflineStrip),
          matching: find.byType(MergeSemantics),
        ),
      );
      final idBefore = tester.getSemantics(find.text(_offline)).id;

      await tester.pumpWidget(
        _host(_strip(BgeOfflineStripState.backOnline, key: key)),
      );
      final after = tester.element(
        find.descendant(
          of: find.byType(BgeOfflineStrip),
          matching: find.byType(MergeSemantics),
        ),
      );

      expect(identical(before, after), isTrue);
      expect(tester.getSemantics(find.text(_back)).id, idBefore);
      expect(
        tester.getSemantics(find.text(_back)),
        matchesSemantics(label: _back, isLiveRegion: true),
      );
      handle.dispose();
    });

    for (final state in [
      BgeOfflineStripState.offline,
      BgeOfflineStripState.backOnline,
    ]) {
      testWidgets('fits 320dp at 200% text: $state', (tester) async {
        await tester.pumpWidget(
          _host(
            _strip(state),
            width: 320,
            textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(BgeOfflineStrip)).width, 320);
        final message = state == BgeOfflineStripState.offline
            ? _offline
            : _back;
        final rect = tester.getRect(find.text(message));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
      });
    }

    testWidgets('reduced motion: size change is instant', (tester) async {
      await tester.pumpWidget(
        _host(_strip(BgeOfflineStripState.hidden), disableAnimations: true),
      );
      await tester.pumpWidget(
        _host(_strip(BgeOfflineStripState.offline), disableAnimations: true),
      );
      await tester.pump();

      final settled = tester.getSize(find.byType(BgeOfflineStrip)).height;
      expect(settled, greaterThan(0));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(BgeOfflineStrip)).height, settled);
    });

    testWidgets('with motion, the size change takes time', (tester) async {
      await tester.pumpWidget(_host(_strip(BgeOfflineStripState.hidden)));
      await tester.pumpWidget(_host(_strip(BgeOfflineStripState.offline)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      final early = tester.getSize(find.byType(BgeOfflineStrip)).height;
      await tester.pumpAndSettle();
      expect(
        early,
        lessThan(tester.getSize(find.byType(BgeOfflineStrip)).height),
      );
    });
  });
}
