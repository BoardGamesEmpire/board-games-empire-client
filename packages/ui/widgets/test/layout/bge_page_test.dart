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

    testWidgets('gives a pane-width page the wider measure', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            width: BgePageWidth.pane,
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // A list row is a label plus a trailing control, not a line of prose, so
      // it reads badly squeezed to the 480 form measure. Still capped, though:
      // the whole point is that no surface stretches across the monitor.
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        BgeTokens.standard.paneMaxWidth,
      );
    });

    testWidgets('is inert on a phone at pane width too', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            width: BgePageWidth.pane,
            child: SizedBox(
              key: Key('greedy'),
              width: double.infinity,
              height: 20,
            ),
          ),
          size: const Size(360, 800),
        ),
      );

      // The cap adapts by being a cap: below it, the content simply fills the
      // window. This is why the variant needs no breakpoint check — see the
      // class doc on why a threshold would have been the wrong primitive.
      final padding = BgeTokens.standard.spaceLg * 2;
      expect(
        tester.getSize(find.byKey(const Key('greedy'))).width,
        360 - padding,
      );
    });
  });

  group('BgePage footer', () {
    testWidgets('pins the footer while the content scrolls', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            footer: const SizedBox(key: Key('footer'), height: 40),
            child: Column(children: List.generate(60, (i) => Text('row $i'))),
          ),
          size: const Size(400, 600),
        ),
      );

      final before = tester.getTopLeft(find.byKey(const Key('footer'))).dy;
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();

      // A submit button that scrolls away is the failure here: on a long form
      // the action becomes unreachable without hunting for it. The footer sits
      // outside the scroll view, so scrolling must not move it.
      expect(tester.getTopLeft(find.byKey(const Key('footer'))).dy, before);
    });

    testWidgets('holds the footer to the same measure as the content', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            footer: SizedBox(
              key: Key('footer'),
              width: double.infinity,
              height: 40,
            ),
            child: SizedBox(height: 20),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // The footer belongs to the content column, not to the window. Letting
      // it span the monitor would put the submit button somewhere the eye
      // never goes — and would reintroduce the measure as a second literal.
      expect(
        tester.getSize(find.byKey(const Key('footer'))).width,
        BgeTokens.standard.contentMaxWidth,
      );
    });

    testWidgets('takes only the height it needs, not the whole cap', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            footer: const SizedBox(key: Key('footer'), height: 48),
            child: Column(children: List.generate(40, (i) => Text('row $i'))),
          ),
          size: const Size(400, 800),
        ),
      );

      // The cap bounds the footer; it must not size it. Filling the cap
      // would strand a 48dp button in the middle of a 400dp empty band and
      // squeeze the content into the top half of the window.
      final scrollHeight = tester
          .getSize(find.byType(SingleChildScrollView).first)
          .height;
      expect(scrollHeight, greaterThan(800 * 0.75));
    });

    testWidgets('keeps an oversized footer reachable at 200% text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          tester,
          BgePage(
            title: const Text('t'),
            // A note plus a button — the shape a real confirmation footer
            // takes. At 1.0 it fits; at 2.0 it is taller than the cap.
            footer: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Sending shares your device details with the server '
                  'administrator so they can reproduce the problem.',
                ),
                const BgeGap.md(),
                FilledButton(
                  key: const Key('act'),
                  onPressed: () {},
                  child: const Text('Send report'),
                ),
              ],
            ),
            child: Column(children: List.generate(20, (i) => Text('row $i'))),
          ),
          size: const Size(320, 480),
          scale: 2,
        ),
      );

      // Capping the footer alone only traded one unreachable region for
      // another: this overflowed by 450px and put the button 400dp below the
      // window, so the action was gone. The footer scrolls within its cap.
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(
        find.byKey(const Key('act')),
        find.byType(SingleChildScrollView).last,
        const Offset(0, -50),
      );
      await tester.pumpAndSettle();

      final button = tester.getRect(find.byKey(const Key('act')));
      expect(button.top, greaterThanOrEqualTo(0));
      expect(button.bottom, lessThanOrEqualTo(480));
      await tester.tap(find.byKey(const Key('act')));
    });

    testWidgets('follows the page measure on a pane page', (tester) async {
      await tester.pumpWidget(
        _host(
          tester,
          const BgePage(
            width: BgePageWidth.pane,
            // Greedy, like the real thing: BgeSubmitButton defaults to
            // `expand: true`. A footer with no intrinsic width shrink-wraps,
            // exactly as the content column does.
            footer: SizedBox(
              key: Key('footer'),
              width: double.infinity,
              height: 40,
            ),
            child: SizedBox(height: 20),
          ),
          size: const Size(2560, 1440),
        ),
      );

      // The footer follows the page's measure rather than a hardcoded one —
      // a form measure here would sit a narrow button under a wide column.
      expect(
        tester.getSize(find.byKey(const Key('footer'))).width,
        BgeTokens.standard.paneMaxWidth,
      );
    });
  });

  testWidgets('never lets a tall footer starve the content', (tester) async {
    await tester.pumpWidget(
      _host(
        tester,
        BgePage(
          title: const Text('t'),
          // A footer that wants far more room than the window has. A
          // realistic version is a note plus a button at 200% text scale
          // on a short landscape window.
          footer: const SizedBox(key: Key('footer'), height: 500),
          child: Column(children: List.generate(30, (i) => Text('row $i'))),
        ),
        size: const Size(320, 480),
        scale: 2,
      ),
    );

    // The footer sits outside the scroll view, so RenderFlex lays it out
    // first with an unbounded main axis and hands Expanded whatever is
    // left — which was zero. That collapses the scroll view and renders
    // the whole page unreachable, the exact failure this widget's scroll
    // guarantee exists to prevent.
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(SingleChildScrollView).first).height,
      greaterThan(0),
    );
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
