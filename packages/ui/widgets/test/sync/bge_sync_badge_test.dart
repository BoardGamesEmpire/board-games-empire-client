import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _waiting = 'Not yet synced';
const _stuck = "Couldn't sync";

Widget _host(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
  double textScale = 1,
}) => hostAtSize(
  tester,
  Scaffold(
    body: Align(alignment: AlignmentDirectional.topStart, child: child),
  ),
  size: size,
  textScale: textScale,
);

BgeStatusColors _colors(WidgetTester tester, Type type) =>
    BgeStatusColors.of(tester.element(find.byType(type)));

void main() {
  group('BgeSyncBadge', () {
    testWidgets('waiting shows the pending icon and the label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgeSyncBadge(state: BgeSyncState.waiting, label: _waiting),
        ),
      );

      final colors = _colors(tester, BgeSyncBadge);
      final icon = find.byIcon(BgeStatusColors.iconFor(BgeStatus.pending));
      expect(icon, findsOneWidget);
      expect(tester.widget<Icon>(icon).color, colors.pending);
      expect(find.text(_waiting), findsOneWidget);
      expect(
        tester.widget<Text>(find.text(_waiting)).style?.color,
        colors.pending,
      );
    });

    testWidgets('stuck shows the conflict icon', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgeSyncBadge(state: BgeSyncState.stuck, label: _stuck),
        ),
      );

      final colors = _colors(tester, BgeSyncBadge);
      final icon = find.byIcon(BgeStatusColors.iconFor(BgeStatus.conflict));
      expect(icon, findsOneWidget);
      expect(
        find.byIcon(BgeStatusColors.iconFor(BgeStatus.pending)),
        findsNothing,
      );
      expect(tester.widget<Icon>(icon).color, colors.conflict);
      expect(
        tester.widget<Text>(find.text(_stuck)).style?.color,
        colors.conflict,
      );
    });

    testWidgets('merged into a parent node, its label is read with the '
        'parent', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          tester,
          const MergeSemantics(
            child: ListTile(
              title: Text('Catan'),
              subtitle: BgeSyncBadge(
                state: BgeSyncState.waiting,
                label: _waiting,
              ),
            ),
          ),
        ),
      );

      final label = tester.getSemantics(find.text('Catan')).label;
      expect(label, contains('Catan'));
      expect(label, contains(_waiting));
      handle.dispose();
    });

    for (final (state, label, status) in [
      (BgeSyncState.waiting, _waiting, BgeStatus.pending),
      (BgeSyncState.stuck, _stuck, BgeStatus.conflict),
    ]) {
      testWidgets('${state.name} at 2.0 text in 120 dp wraps without '
          'overflow', (tester) async {
        await tester.pumpWidget(
          _host(
            tester,
            BgeSyncBadge(state: state, label: label),
            size: const Size(120, 600),
            textScale: 2,
          ),
        );

        expect(tester.takeException(), isNull);
        final style = Theme.of(
          tester.element(find.byType(BgeSyncBadge)),
        ).textTheme.labelMedium!;
        final size = 2 * style.fontSize!;
        // The icon grows with its label, so the two still read as one
        // badge.
        expect(
          tester.getSize(find.byIcon(BgeStatusColors.iconFor(status))),
          Size.square(size),
        );
        final drawn = tester.getRect(find.text(label));
        expect(drawn.right, lessThanOrEqualTo(120));
        // More than one line: the label wrapped inside the row.
        expect(drawn.height, greaterThan(1.5 * size * (style.height ?? 1)));
      });
    }

    for (final (name, theme, floor) in [
      ('light', BgeTheme.light(), Wcag.aaNormalText),
      ('dark', BgeTheme.dark(), Wcag.aaNormalText),
      ('high-contrast light', BgeTheme.highContrastLight(), Wcag.aaaNormalText),
      ('high-contrast dark', BgeTheme.highContrastDark(), Wcag.aaaNormalText),
    ]) {
      testWidgets('on a container, the words are onSurfaceVariant and the '
          'icon keeps its status colour, each clearing its floor on every '
          'container ground, in $name', (tester) async {
        final scheme = theme.colorScheme;
        final grounds = {
          'surfaceContainerLowest': scheme.surfaceContainerLowest,
          'surfaceContainerLow': scheme.surfaceContainerLow,
          'surfaceContainer': scheme.surfaceContainer,
          'surfaceContainerHigh': scheme.surfaceContainerHigh,
          'surfaceContainerHighest': scheme.surfaceContainerHighest,
        };
        for (final (state, label, status) in [
          (BgeSyncState.waiting, _waiting, BgeStatus.pending),
          (BgeSyncState.stuck, _stuck, BgeStatus.conflict),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: BgeSyncBadge(
                  state: state,
                  label: label,
                  onContainer: true,
                ),
              ),
            ),
          );

          final words = tester.widget<Text>(find.text(label)).style!.color!;
          final icon = tester
              .widget<Icon>(find.byIcon(BgeStatusColors.iconFor(status)))
              .color!;
          expect(words, scheme.onSurfaceVariant, reason: state.name);
          expect(
            icon,
            _colors(tester, BgeSyncBadge).colorFor(status),
            reason: state.name,
          );
          for (final MapEntry(key: ground, value: color) in grounds.entries) {
            expect(
              Wcag.contrastRatio(words, color),
              greaterThanOrEqualTo(floor),
              reason: '${state.name} words on $ground',
            );
            // The icon is a non-text mark beside words that say the same.
            expect(
              Wcag.contrastRatio(icon, color),
              greaterThanOrEqualTo(Wcag.aaNonText),
              reason: '${state.name} icon on $ground',
            );
          }
        }
      });
    }
  });

  group('BgeSyncMark', () {
    for (final (state, status) in [
      (BgeSyncState.waiting, BgeStatus.pending),
      (BgeSyncState.stuck, BgeStatus.conflict),
    ]) {
      testWidgets('${state.name} draws the ${status.name} icon on an '
          'onStatus disc', (tester) async {
        await tester.pumpWidget(_host(tester, BgeSyncMark(state: state)));

        final colors = _colors(tester, BgeSyncMark);
        final icon = find.byIcon(BgeStatusColors.iconFor(status));
        expect(icon, findsOneWidget);
        expect(tester.widget<Icon>(icon).color, colors.colorFor(status));
        final disc = find.descendant(
          of: find.byType(BgeSyncMark),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).shape == BoxShape.circle &&
                (w.decoration as BoxDecoration).color == colors.onStatus,
          ),
        );
        expect(disc, findsOneWidget);
        expect(find.descendant(of: disc, matching: icon), findsOneWidget);
      });
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets("at ${scale}x text the glyph is the cover icons' size, "
          'scaled', (tester) async {
        await tester.pumpWidget(
          _host(
            tester,
            const BgeSyncMark(state: BgeSyncState.stuck),
            textScale: scale,
          ),
        );

        // The size of the cover's other glyphs, the expansions badge's
        // puzzle piece and the missing-part tab's broken link, so the two
        // states' shapes can be told apart without their colours.
        final tokens = BgeTokens.of(tester.element(find.byType(BgeSyncMark)));
        final glyph = scale * tokens.spaceMd;
        expect(
          tester.getSize(
            find.byIcon(BgeStatusColors.iconFor(BgeStatus.conflict)),
          ),
          Size.square(glyph),
        );
        expect(
          tester.getSize(find.byType(BgeSyncMark)),
          Size.square(glyph + 2 * tokens.spaceXs),
        );
      });
    }

    testWidgets('mark adds nothing to the semantics tree', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          tester,
          Semantics(
            container: true,
            label: 'Azul',
            child: const BgeSyncMark(state: BgeSyncState.stuck),
          ),
        ),
      );

      // The nearest node is the host's, whose label is its own alone.
      final node = tester.getSemantics(find.byType(BgeSyncMark));
      expect(node.label, 'Azul');
      expect(node.childrenCount, 0);
      handle.dispose();
    });
  });
}
