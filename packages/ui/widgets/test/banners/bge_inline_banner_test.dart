import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? BgeTheme.light(),
  home: Scaffold(body: child),
);

/// A banner hosted in a real scroll view, tall enough that the banner can be
/// off-viewport in either direction.
///
/// The message is a [ValueNotifier] rather than a `pumpWidget` argument so the
/// scroll view keeps its identity — and its offset — while the banner appears,
/// which is what happens on a real screen when a bloc emits a failure. A null
/// message means no banner.
Widget _revealHost({
  required ValueNotifier<String?> message,
  required ScrollController controller,
  required bool bannerAboveFiller,
  bool reveal = true,
  bool disableAnimations = false,
  double textScale = 1,
  bool inHorizontalStrip = false,
  bool reverse = false,
}) => MediaQuery(
  data: MediaQueryData(
    size: const Size(320, 480),
    disableAnimations: disableAnimations,
    // Carried explicitly: a MediaQueryData built from scratch defaults
    // textScaler to no scaling, which silently pinned every reveal case at
    // 1.0 — the scale at which a banner always fits, and so the scale that
    // cannot exercise the top-edge alignment this widget exists to get right.
    textScaler: TextScaler.linear(textScale),
  ),
  child: MaterialApp(
    theme: BgeTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        controller: controller,
        reverse: reverse,
        child: ValueListenableBuilder<String?>(
          valueListenable: message,
          builder: (context, value, _) {
            Widget banner = value == null
                ? const SizedBox.shrink()
                : BgeInlineBanner(
                    tone: BgeBannerTone.error,
                    message: value,
                    reveal: reveal,
                  );
            if (inHorizontalStrip && value != null) {
              // A nearer scrollable on the other axis. The reveal has to reach
              // past it to the vertical page it is actually hosted in.
              banner = SizedBox(
                // Tall enough for the banner itself — a strip that clips it
                // would fail on overflow before reaching the assertion.
                height: 140,
                // A SingleChildScrollView, not a ListView: a ListView is a
                // lazy list, and a banner inside one is deliberately skipped,
                // which would make this case pass for the wrong reason. The
                // concern here is only the axis of the nearest scrollable.
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: 280, child: banner),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (bannerAboveFiller) banner,
                const SizedBox(height: 1200, child: Placeholder()),
                if (!bannerAboveFiller) banner,
                // Content below the banner slot, so a banner hosted low in
                // the column can still have its top edge inside the viewport.
                // Without it the banner is the last child and its start is
                // only ever reachable at maxScrollExtent, which makes the
                // already-visible case impossible to construct.
                //
                // Taller than the 480dp viewport on purpose: the scroll extent
                // has to allow the banner's top edge to actually reach the
                // viewport start, or a correct reveal still lands a few dp
                // short and the assertions here would be measuring the
                // harness's geometry rather than the widget's behaviour.
                const SizedBox(height: 600, child: Placeholder()),
              ],
            );
          },
        ),
      ),
    ),
  ),
);

/// Sets the render surface to a phone-sized window. `MediaQueryData.size` is
/// metadata and constrains nothing, so the viewport height the reveal scrolls
/// within has to come from the view.
void _useNarrowWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 480);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

RenderBox _scrollBox(WidgetTester tester) =>
    tester.renderObject<RenderBox>(find.byType(Scrollable));

/// The banner's top edge in the scroll viewport's own coordinate space.
///
/// This is the measure the reveal exists to fix, and the one `findsOneWidget`
/// cannot see: a banner scrolled past is present in the tree with a negative
/// top edge.
double _bannerTop(WidgetTester tester) => tester
    .renderObject<RenderBox>(find.byType(BgeInlineBanner))
    .localToGlobal(Offset.zero, ancestor: _scrollBox(tester))
    .dy;

bool _bannerTopVisible(WidgetTester tester) {
  final top = _bannerTop(tester);
  return top >= 0 && top < _scrollBox(tester).size.height;
}

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

    testWidgets('an action inherits the banner tone, not the ambient accent', (
      tester,
    ) async {
      // A plain TextButton defaults to colorScheme.primary — 2.92:1 against
      // the dark error container, and it fails the same way on every toned
      // container. The action must take the banner's own foreground.
      final scheme = BgeTheme.dark().colorScheme;

      await tester.pumpWidget(
        _host(
          BgeInlineBanner(
            tone: BgeBannerTone.error,
            message: 'Could not reach the server.',
            action: TextButton(onPressed: () {}, child: const Text('Retry')),
          ),
          theme: BgeTheme.dark(),
        ),
      );

      final label = tester.widget<Text>(find.text('Retry'));
      final resolved =
          DefaultTextStyle.of(tester.element(find.text('Retry'))).style.color ??
          label.style?.color;

      expect(
        resolved,
        scheme.onErrorContainer,
        reason:
            'the action should render in onErrorContainer (7.01:1), not '
            'primary (2.92:1)',
      );
      expect(resolved, isNot(scheme.primary));
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
          // The text scaler applies despite this MediaQuery sitting above
          // MaterialApp — `MediaQuery.fromView` comes from `View`, which is
          // higher still, so the nearest one wins. Width comes from the
          // explicit SizedBox, not from `MediaQueryData.size`, which is
          // metadata and constrains nothing.
          //
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
  group('BgeInlineBanner reveal', () {
    testWidgets('scrolls its top edge into view when it appears above the '
        'viewport', (tester) async {
      // The bug (#209): the banner announces itself, so a screen-reader user
      // is told. A sighted user who had scrolled down to reach the submit
      // button sees a button that did nothing.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
        ),
      );
      controller.jumpTo(600);
      await tester.pump();

      message.value = 'That address is not a BGE server.';
      await tester.pumpAndSettle();

      expect(
        _bannerTopVisible(tester),
        isTrue,
        reason: 'the start of the message has to be on screen to be read',
      );
      expect(
        _bannerTop(tester),
        moreOrLessEquals(0, epsilon: 0.5),
        reason:
            'the top edge aligns to the viewport start, not the centre: at '
            '200% text scale the banner is taller than the viewport, so a '
            'centred reveal shows the middle of a wrapped sentence',
      );
    });

    testWidgets('scrolls its top edge into view when it appears below the '
        'viewport', (tester) async {
      // ServerAddForm places its banner between the fields and the submit
      // button and submits on the alias field's keyboard done action
      // (`server_add_form.dart:141`), so a user can submit while the banner's
      // position is still below the fold.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: false,
        ),
      );
      expect(controller.offset, 0, reason: 'sanity: starts at the top');

      message.value = 'That address is not a BGE server.';
      await tester.pumpAndSettle();

      expect(_bannerTopVisible(tester), isTrue);
      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        reason:
            'revealed an inset below the viewport start, not flush against '
            'it: flush means flush against the app bar on a BgePage',
      );
    });

    testWidgets('does not scroll when its top edge is already visible', (
      tester,
    ) async {
      // A reveal that fires unconditionally yanks the viewport on the one call
      // site that never had the bug.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: false,
        ),
      );
      // Below the 1200dp filler, so at this offset the banner appears 200dp
      // down a 480dp viewport — its start is readable where it stands. This is
      // the ServerAddForm shape: inserting the banner above the submit button
      // puts it in the space the button occupied.
      controller.jumpTo(1000);
      await tester.pump();

      message.value = 'That address is not a BGE server.';
      await tester.pumpAndSettle();

      expect(_bannerTopVisible(tester), isTrue, reason: 'sanity');
      expect(
        controller.offset,
        1000,
        reason:
            'the user put the viewport here; a banner already readable '
            'from its start is not a reason to move it',
      );
    });

    testWidgets('re-reveals when the message changes under a mounted banner', (
      tester,
    ) async {
      // The live region re-announces when its content changes, so a screen
      // reader hears the second failure. Without this the sighted user does
      // not see it: the element is updated, not re-created, so a
      // first-appearance-only reveal never fires.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(
        'That address is not a BGE '
        'server.',
      );
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(600);
      await tester.pump();
      expect(
        _bannerTopVisible(tester),
        isFalse,
        reason: 'sanity: scrolled off',
      );

      message.value = 'You are offline. Connect to a network and try again.';
      await tester.pumpAndSettle();

      expect(_bannerTopVisible(tester), isTrue);
    });

    testWidgets('reveal: false leaves the viewport alone', (tester) async {
      // #49's offline indicator is persistent, not an outcome. One that
      // self-scrolls on every mount fights a restored scroll position.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
          reveal: false,
        ),
      );
      controller.jumpTo(600);
      await tester.pump();

      message.value = 'You are offline.';
      await tester.pumpAndSettle();

      expect(controller.offset, 600);
      expect(_bannerTopVisible(tester), isFalse);
    });

    testWidgets('jumps instead of animating under OS reduced motion', (
      tester,
    ) async {
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
          disableAnimations: true,
        ),
      );
      controller.jumpTo(600);
      await tester.pump();

      message.value = 'That address is not a BGE server.';
      // Two frames, no elapsed time: one for the banner to lay out and fire
      // its post-frame reveal, one for the scroll position to take effect.
      await tester.pump();
      await tester.pump();

      expect(
        controller.offset,
        moreOrLessEquals(0, epsilon: 0.5),
        reason:
            'BgeMotion.durationOf collapses to Duration.zero, so the '
            'reveal is complete with no time elapsed',
      );
    });

    testWidgets('animates the reveal when motion is not reduced', (
      tester,
    ) async {
      // The counterpart to the reduced-motion case: without it, a hardcoded
      // Duration.zero would pass that test and never be caught.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
        ),
      );
      controller.jumpTo(600);
      await tester.pump();

      message.value = 'That address is not a BGE server.';
      await tester.pump();
      await tester.pump();

      expect(
        controller.offset,
        greaterThan(0),
        reason: 'the scroll should still be in flight with no time elapsed',
      );
      await tester.pumpAndSettle();
      expect(controller.offset, moreOrLessEquals(0, epsilon: 0.5));
    });

    testWidgets(
      'reveals a banner showing only a sliver above the bottom edge',
      (tester) async {
        // A top edge inside the viewport is not the same as a readable banner.
        // ServerAddForm inserts its banner into the space the submit button
        // occupied, near the bottom of the viewport, so a few dp of tinted
        // container can be all that lands on screen — #209 unfixed, but passing
        // a top-edge-only check.
        _useNarrowWindow(tester);
        final message = ValueNotifier<String?>(null);
        addTearDown(message.dispose);
        final controller = ScrollController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          _revealHost(
            message: message,
            controller: controller,
            bannerAboveFiller: false,
          ),
        );
        // Banner slot sits at content y=1200; at this offset its top lands 10dp
        // above the 480dp viewport's bottom edge, so 10dp of it shows.
        controller.jumpTo(730);
        await tester.pump();

        message.value = 'That address is not a BGE server.';
        await tester.pumpAndSettle();

        expect(
          _bannerTop(tester),
          moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
          reason: 'a 10dp sliver of an error message is not a revealed banner',
        );
      },
    );

    testWidgets('leaves a scroll already in progress alone', (tester) async {
      // #209 asks for care "not to fight a user who has deliberately scrolled
      // elsewhere". In a lazily-built list every newly realized banner would
      // otherwise call ensureVisible mid-drag and pin the viewport.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
        ),
      );
      controller.jumpTo(600);
      await tester.pump();

      // A drag held open, so the position is actively scrolling.
      final drag = await tester.startGesture(const Offset(160, 240));
      await drag.moveBy(const Offset(0, -40));
      await tester.pump();
      final held = controller.offset;
      expect(
        controller.position.isScrollingNotifier.value,
        isTrue,
        reason: 'sanity: the drag must be live for this test to mean anything',
      );

      message.value = 'That address is not a BGE server.';
      await tester.pump();
      await tester.pump();

      expect(
        controller.offset,
        held,
        reason: 'the reveal must not seize a viewport the user is dragging',
      );

      // The finger keeps moving. This is the assertion with teeth: starting a
      // driven scroll cancels the drag activity, so a reveal that fired here
      // would leave the offset stuck while the user is still dragging. Merely
      // checking the offset had not moved yet would pass either way, because
      // no time has elapsed for a driven scroll to travel.
      await drag.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(
        controller.offset,
        moreOrLessEquals(held + 60, epsilon: 1),
        reason: 'the viewport must still follow the finger',
      );

      await drag.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a failure arriving mid-gesture is revealed once the gesture '
        'ends', (tester) async {
      // Skipping a reveal during a user gesture must not DROP it. A submit's
      // failure can land while the user is flicking the page, and before this
      // was deferred the banner stayed off screen until some later copy change
      // — the accessibility guarantee lapsing silently, which is the failure
      // mode #209 is about.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
        ),
      );
      controller.jumpTo(600);
      await tester.pump();

      final drag = await tester.startGesture(const Offset(160, 240));
      await drag.moveBy(const Offset(0, -40));
      await tester.pump();

      // The failure lands mid-gesture.
      message.value = 'That address is not a BGE server.';
      await tester.pump();
      await tester.pump();
      expect(
        _bannerTopVisible(tester),
        isFalse,
        reason: 'sanity: nothing moves while the finger is down',
      );

      await drag.up();
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(0, epsilon: 0.5),
        reason: 'the deferred reveal has to land once the user stops scrolling',
      );
    });

    testWidgets('a banner built as a lazy list row never asks for the '
        'viewport', (tester) async {
      // Every row a lazy list realizes would otherwise demand the viewport,
      // and the demands cascade: measured before this was guarded, this list
      // ran away to offset 23384 on first layout and could not be scrolled
      // back. A list row is not an arriving outcome.
      _useNarrowWindow(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(320, 480)),
          child: MaterialApp(
            theme: BgeTheme.light(),
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemExtent: 120,
                itemCount: 200,
                itemBuilder: (context, i) => i % 5 == 0
                    ? const BgeInlineBanner(
                        tone: BgeBannerTone.error,
                        message: 'row banner',
                      )
                    : const Placeholder(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        0,
        reason: 'first layout must leave the list where it started',
      );

      controller.jumpTo(2000);
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        2000,
        reason: 'the rows realized by the jump must not scroll it back',
      );
    });

    testWidgets('reveals past a nearer horizontal scroller', (tester) async {
      // Scrollable.maybeOf takes the nearest scrollable of ANY axis. Measuring
      // a vertical `.dy` against a horizontal viewport reads as "visible" and
      // vetoes the reveal on the page that actually needs to move.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
          inHorizontalStrip: true,
        ),
      );
      controller.jumpTo(600);
      await tester.pump();

      message.value = 'That address is not a BGE server.';
      await tester.pumpAndSettle();

      expect(
        controller.offset,
        lessThan(600),
        reason: 'the vertical page is the scrollable that has to move',
      );
    });

    testWidgets('aligns the top edge of a banner taller than the viewport at '
        '200% text scale', (tester) async {
      // The stated reason for choosing the top edge over centring. At this
      // scale a real error string measures 774dp against a 480dp viewport, so
      // a centred reveal would show the middle of a wrapped sentence with the
      // first line off screen.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: false,
          textScale: 2,
        ),
      );
      expect(controller.offset, 0, reason: 'sanity: starts at the top');

      message.value =
          'Plain http is only allowed for local and private network '
          'addresses. Use https for this server.';
      await tester.pumpAndSettle();

      final bannerHeight = tester
          .renderObject<RenderBox>(find.byType(BgeInlineBanner))
          .size
          .height;
      expect(
        bannerHeight,
        greaterThan(_scrollBox(tester).size.height),
        reason:
            'sanity: this case only means something while the banner is '
            'taller than the viewport',
      );
      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        reason: 'the first line has to be the line on screen',
      );
    });

    testWidgets('reveals in a reverse scroll view, where increasing pixels '
        'moves content the other way', (tester) async {
      // The viewport-to-offset conversion is signed. Under AxisDirection.up a
      // banner above the viewport computes a NEGATIVE target, clamps at the
      // minimum extent and stays hidden — measured at -794dp before this was
      // handled. No surface here scrolls in reverse today; the widget is
      // shared, and the correction is a sign.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(null);
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
          reverse: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        controller.position.axisDirection,
        AxisDirection.up,
        reason: 'sanity: this case is about the reversed axis',
      );

      message.value = 'That address is not a BGE server.';
      await tester.pumpAndSettle();

      expect(
        _bannerTopVisible(tester),
        isTrue,
        reason: 'the reveal has to scroll the other way when the axis does',
      );
    });

    testWidgets('reveal turning on is itself an appearance', (tester) async {
      // A state-derived flag has to be able to come back on. Copy is unchanged
      // across the flip, so the copy-change path cannot cover it, and nothing
      // else would ever schedule the reveal.
      _useNarrowWindow(tester);
      final message = ValueNotifier<String?>(
        'That address is not a BGE server.',
      );
      addTearDown(message.dispose);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
          reveal: false,
        ),
      );
      controller.jumpTo(600);
      await tester.pumpAndSettle();
      expect(
        _bannerTopVisible(tester),
        isFalse,
        reason: 'sanity: nothing reveals while the flag is off',
      );

      await tester.pumpWidget(
        _revealHost(
          message: message,
          controller: controller,
          bannerAboveFiller: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(0, epsilon: 0.5),
        reason: 'the banner has become an outcome; that is an appearance',
      );
    });

    testWidgets('is inert with no Scrollable ancestor', (tester) async {
      // The golden suite renders the banner bare — MediaQuery > Theme >
      // Material > Padding > banner (`bge_widgets_golden_test.dart:116-138`).
      // An unguarded ensureVisible throws there.
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Theme(
              data: BgeTheme.light(),
              child: Material(
                child: Padding(
                  padding: EdgeInsets.all(BgeTokens.standard.spaceMd),
                  child: const BgeInlineBanner(
                    tone: BgeBannerTone.error,
                    message: 'That address is not a BGE server.',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
