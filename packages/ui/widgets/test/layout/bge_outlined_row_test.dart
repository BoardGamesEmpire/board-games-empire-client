import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _leadingKey = Key('leading');
const _longTitle = 'Twilight Imperium: Fourth Edition';

Widget _host(Widget child, {ThemeData? theme, double scale = 1.0}) =>
    MaterialApp(
      theme: theme ?? BgeTheme.light(),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: app!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Widget _row(String title, {String? subtitle}) => BgeOutlinedRow(
  child: ListTile(
    leading: const SizedBox(key: _leadingKey, width: 56, height: 56),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
  ),
);

void main() {
  group('BgeOutlinedRow', () {
    Finder outline(BuildContext context) => find.descendant(
      of: find.byType(BgeOutlinedRow),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration ==
                ShapeDecoration(shape: BgeOutlinedRow.shapeOf(context)),
      ),
    );

    for (final (name, theme, color) in <(String, ThemeData, Color)>[
      ('light', BgeTheme.light(), BgeColorSchemes.light.outlineVariant),
      (
        'highContrastLight',
        BgeTheme.highContrastLight(),
        BgeColorSchemes.highContrastLight.outline,
      ),
    ]) {
      testWidgets('$name: the row paints a radiusMd outline in rowOutline '
          'around its whole child', (tester) async {
        late BuildContext outer;
        await tester.pumpWidget(
          _host(
            Builder(
              builder: (context) {
                outer = context;
                return const BgeOutlinedRow(child: ListTile(title: Text('R')));
              },
            ),
            theme: theme,
          ),
        );

        final shape = BgeOutlinedRow.shapeOf(outer) as RoundedRectangleBorder;
        expect(
          shape.borderRadius,
          BorderRadius.circular(BgeTokens.standard.radiusMd),
        );
        expect(shape.side.color, color);
        expect(outline(outer), findsOneWidget);
      });
    }

    testWidgets('a ListTile and a CheckboxListTile inside take the side-less '
        'radiusMd shape', (tester) async {
      late BuildContext outer;
      late BuildContext listCtx;
      late BuildContext checkCtx;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              outer = context;
              return Column(
                children: [
                  BgeOutlinedRow(
                    child: Builder(
                      builder: (context) {
                        listCtx = context;
                        return const ListTile(title: Text('Row'));
                      },
                    ),
                  ),
                  BgeOutlinedRow(
                    child: CheckboxListTile(
                      value: false,
                      onChanged: (_) {},
                      title: const Text('Row'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      checkCtx = tester.element(find.byType(CheckboxListTile));
      final expected = BgeOutlinedRow.tileShapeOf(outer);
      expect(ListTileTheme.of(listCtx).shape, expected);
      expect(ListTileTheme.of(checkCtx).shape, expected);
      expect((expected as RoundedRectangleBorder).side, BorderSide.none);
      expect(
        expected.borderRadius,
        BorderRadius.circular(BgeTokens.standard.radiusMd),
      );
    });

    testWidgets('a tile with its buttons beneath it is outlined whole', (
      tester,
    ) async {
      late BuildContext outer;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              outer = context;
              return BgeOutlinedRow(
                child: Column(
                  children: [
                    const ListTile(key: Key('tile'), title: Text('Invite')),
                    Row(
                      children: [
                        TextButton(
                          key: const Key('button'),
                          onPressed: () {},
                          child: const Text('Accept'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

      final box = tester.getRect(outline(outer));
      final tile = tester.getRect(find.byKey(const Key('tile')));
      final button = tester.getRect(find.byKey(const Key('button')));
      for (final inner in [tile, button]) {
        expect(box.left, lessThanOrEqualTo(inner.left));
        expect(box.top, lessThanOrEqualTo(inner.top));
        expect(box.right, greaterThanOrEqualTo(inner.right));
        expect(box.bottom, greaterThanOrEqualTo(inner.bottom));
      }
    });

    testWidgets('a ListTile outside one has no shape from it', (tester) async {
      late BuildContext inner;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              inner = context;
              return const ListTile(title: Text('Row'));
            },
          ),
        ),
      );

      expect(ListTileTheme.of(inner).shape, isNull);
    });

    testWidgets('rows are spaced by spaceSm', (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              BgeOutlinedRow(
                child: ListTile(key: Key('a'), title: Text('A')),
              ),
              BgeOutlinedRow(
                child: ListTile(key: Key('b'), title: Text('B')),
              ),
            ],
          ),
        ),
      );

      final gap =
          tester.getTopLeft(find.byKey(const Key('b'))).dy -
          tester.getBottomLeft(find.byKey(const Key('a'))).dy;
      expect(gap, BgeTokens.standard.spaceSm);
    });

    for (final (scale, title, subtitle) in <(double, String, String?)>[
      (2.0, _longTitle, '2017 · 3–6 players · 240–480 min'),
      (1.0, 'Wingspan', null),
    ]) {
      testWidgets('at 320dp and ${scale}x text, the thumbnail is level with '
          'the title and nothing overflows', (tester) async {
        await tester.pumpWidget(
          hostAtSize(
            tester,
            Scaffold(
              body: SingleChildScrollView(
                child: _row(title, subtitle: subtitle),
              ),
            ),
            size: const Size(320, 800),
            textScale: scale,
          ),
        );

        final leadingTop = tester.getTopLeft(find.byKey(_leadingKey)).dy;
        final titleFinder = find.text(title);
        final titleTop = tester.getTopLeft(titleFinder).dy;
        final paragraph = tester.renderObject<RenderParagraph>(titleFinder);
        final firstLineBottom =
            paragraph
                .getBoxesForSelection(
                  const TextSelection(baseOffset: 0, extentOffset: 1),
                )
                .first
                .bottom +
            titleTop;
        // A tall row hangs the thumbnail from the title's top; a one-line row
        // is shorter than its thumbnail, so the title is centred on it and
        // starts below the thumbnail's top. Either way the thumbnail's top is
        // within the title's first line.
        if (subtitle != null) {
          expect(titleTop, lessThanOrEqualTo(leadingTop));
        } else {
          // titleHeight centres a one-line 56dp tile's title within the
          // thumbnail's span.
          expect(titleTop, greaterThanOrEqualTo(leadingTop));
          expect(
            titleTop + paragraph.size.height,
            lessThanOrEqualTo(leadingTop + 56),
          );
        }
        expect(leadingTop, lessThan(firstLineBottom));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
