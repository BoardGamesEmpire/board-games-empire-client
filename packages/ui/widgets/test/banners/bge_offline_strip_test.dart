import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _offline = "You're offline. Changes will sync when you reconnect.";
const _back = 'Back online';
const _detail = '3 changes waiting';

Widget _strip(BgeOfflineStripState state, {Key? key, String? detail}) =>
    BgeOfflineStrip(
      key: key,
      state: state,
      offlineMessage: _offline,
      backOnlineMessage: _back,
      detail: detail,
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

    group('a detail (#47)', () {
      final detail = find.byKey(BgeOfflineStrip.detailKey);

      testWidgets('detail shows under the offline message', (tester) async {
        await tester.pumpWidget(
          _host(_strip(BgeOfflineStripState.offline, detail: _detail)),
        );

        expect(detail, findsOneWidget);
        expect(tester.widget<Text>(detail).data, _detail);
        final message = tester.getRect(find.text(_offline));
        final line = tester.getRect(detail);
        expect(line.top, greaterThanOrEqualTo(message.bottom));
        expect(line.left, message.left, reason: 'past the icon, as it is');
        expect(
          tester.widget<Text>(detail).style,
          tester.widget<Text>(find.text(_offline)).style,
          reason: 'in the same style',
        );
      });

      testWidgets('detail is outside the live region', (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _host(_strip(BgeOfflineStripState.offline, detail: _detail)),
        );

        final live = tester.getSemantics(find.text(_offline));
        expect(live, matchesSemantics(label: _offline, isLiveRegion: true));
        expect(live.label, isNot(contains(_detail)));

        final own = tester.getSemantics(detail);
        expect(own.id, isNot(live.id));
        expect(own, matchesSemantics(label: _detail));
        for (SemanticsNode? node = own; node != null; node = node.parent) {
          expect(
            node.flagsCollection.isLiveRegion,
            isFalse,
            reason: 'no live region holds it: node ${node.id}',
          );
        }
        // Read after the message, as it is drawn.
        expect(
          [
            for (final node
                in tester.semantics.simulatedAccessibilityTraversal())
              node.id,
          ],
          containsAllInOrder([live.id, own.id]),
        );
        handle.dispose();
      });

      testWidgets("changing detail does not change the live region's label", (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _host(_strip(BgeOfflineStripState.offline)),
        );
        final live = tester.getSemantics(find.text(_offline));
        final (id, label) = (live.id, live.label);

        for (final next in [_detail, '2 changes waiting', null]) {
          await tester.pumpWidget(
            _host(_strip(BgeOfflineStripState.offline, detail: next)),
          );
          await tester.pumpAndSettle();

          final after = tester.getSemantics(find.text(_offline));
          expect((after.id, after.label), (id, label), reason: '$next');
          expect(after.flagsCollection.isLiveRegion, isTrue);
          if (next != null) {
            expect(tester.getSemantics(detail).label, next);
          }
        }
        handle.dispose();
      });

      testWidgets('detail is hidden while back online', (tester) async {
        final handle = tester.ensureSemantics();
        for (final state in [
          BgeOfflineStripState.backOnline,
          BgeOfflineStripState.hidden,
        ]) {
          await tester.pumpWidget(_host(_strip(state, detail: _detail)));
          await tester.pumpAndSettle();

          expect(detail, findsNothing, reason: '$state');
          expect(find.text(_detail), findsNothing, reason: '$state');
          expect(
            find.bySemanticsLabel(_detail),
            findsNothing,
            reason: '$state',
          );
        }
        handle.dispose();
      });

      testWidgets('at 320dp and 200% text a long detail wraps, whole and '
          'under the message', (tester) async {
        // Long enough to wrap at 320dp and 2.0, in real fonts as in the
        // test's.
        const long = '12 changes waiting to sync, 2 of them stuck';
        await tester.pumpWidget(
          _host(
            _strip(BgeOfflineStripState.offline, detail: long),
            width: 320,
            textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
          ),
        );

        expect(tester.takeException(), isNull);
        final strip = tester.getRect(find.byType(BgeOfflineStrip));
        final line = tester.getRect(detail);
        expect(strip.intersect(line), line, reason: 'inside the strip');
        // Lined up at 2.0 too, which a theme that scaled icons with the text
        // would break.
        expect(line.left, tester.getRect(find.text(_offline)).left);

        final paragraph = tester.renderObject<RenderParagraph>(detail);
        final lines = {
          for (final box in paragraph.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: long.length),
          ))
            box.top,
        };
        expect(lines.length, greaterThan(1), reason: 'it wraps');
        expect(
          paragraph.getMinIntrinsicHeight(paragraph.size.width),
          lessThanOrEqualTo(paragraph.size.height),
          reason: 'every line has room: nothing is clipped',
        );
      });
    });
  });
}
