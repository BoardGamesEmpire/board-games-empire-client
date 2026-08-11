import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Sets the actual render surface, then hosts [child].
///
/// `MediaQueryData.size` is **metadata, not layout constraints** — a widget
/// under `MediaQuery(size: Size(320, 480))` still lays out against the test
/// view's 800x600. Every "narrow window" case here previously set only that
/// field, so it ran at 800 wide and tested nothing about narrow windows. The
/// size has to go on `tester.view`.
///
/// The text scaler is different: an ancestor `MediaQuery` IS effective. The
/// framework's own `MediaQuery.fromView` is inserted by `View`, ABOVE the
/// widget under test — `WidgetsApp` inserts none of its own — so this wrapper
/// sits below it and wins. Verified, not assumed.
Widget _host(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(400, 800),
  double scale = 1,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  return MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
    child: MaterialApp(theme: BgeTheme.light(), home: child),
  );
}

void main() {
  group('BgePage content width', () {
    testWidgets('constrains the content column on a wide window', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          // A child that WANTS the full width. Measuring `Text('body')` would
          // measure its ~30px intrinsic width, which is under 480 whether or
          // not the constraint exists — that assertion passed with BgePage's
          // ConstrainedBox deleted entirely, so it tested nothing.
          const BgePage(
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // Unconstrained, a form stretches across the whole monitor and a label
      // ends up a forearm away from its input. Asserted as equality, not a
      // bound: a greedy child should be capped at exactly contentMaxWidth.
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        BgeTokens.standard.contentMaxWidth,
      );
    });

    testWidgets('is inert on a phone-width window', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(360, 800),
        ),
      );

      // 480 is wider than any phone, so the constraint must not bite. Asserted
      // by measuring rather than by "nothing threw": the greedy child should
      // get the whole window minus padding, which also proves the window is
      // actually 360 wide — the earlier version set only `MediaQueryData.size`
      // and silently ran at the 800px default.
      final padding = BgeTokens.standard.spaceLg * 2;
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        360 - padding,
      );
    });
  });

  group('BgePage scrolling', () {
    testWidgets('scrolls content that overflows at large text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            child: Column(children: List.generate(40, (i) => Text('row $i'))),
          ),
          size: const Size(320, 480),
          scale: 2,
        ),
      );

      // The failure mode this prevents is not cosmetic: without a scroll view,
      // the bottom of a form is permanently unreachable at the 200% text scale
      // the app guarantees.
      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('scrolls even when the content fits', (tester) async {
      await tester.pumpWidget(
        _host(tester, const BgePage(child: Text('short'))),
      );

      // Scroll is not opt-in per screen; each new screen re-deciding it is how
      // one of them gets it wrong.
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });
  });

  group('BgePage chrome', () {
    testWidgets('shows an app bar only when a title is given', (tester) async {
      await tester.pumpWidget(_host(tester, const BgePage(child: Text('b'))));
      expect(find.byType(AppBar), findsNothing);

      await tester.pumpWidget(
        _host(tester, const BgePage(title: Text('Settings'), child: Text('b'))),
      );
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('centers vertically only when asked', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(centerVertically: true, child: Text('centered')),
          size: const Size(400, 800),
        ),
      );

      final center = tester.getCenter(find.text('centered'));
      // Roughly mid-viewport rather than pinned to the top.
      expect(center.dy, greaterThan(200));
      expect(tester.takeException(), isNull);
    });
  });
}
