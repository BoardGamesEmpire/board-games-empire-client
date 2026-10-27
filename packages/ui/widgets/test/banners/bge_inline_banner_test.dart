import 'dart:async' show unawaited;

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/src/banners/banner_action_layout.dart';
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
  bool keyboardFocus = false,
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
        // Focus inside the page, for the keyboard cases: the default PageUp
        // and PageDown shortcuts scroll the scroll view around the focus.
        child: Focus(
          autofocus: keyboardFocus,
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
  ),
);

/// Sets the render surface to a phone-sized window. `MediaQueryData.size` is
/// metadata and constrains nothing, so the viewport height the reveal scrolls
/// within has to come from the view.
void _useNarrowWindow(WidgetTester tester) {
  useViewSize(tester, const Size(320, 480));
}

/// The banner's top edge in the scroll viewport's own coordinate space.
double _bannerTop(WidgetTester tester) =>
    topInViewport(tester, find.byType(BgeInlineBanner));

bool _bannerTopVisible(WidgetTester tester) {
  final top = _bannerTop(tester);
  return top >= 0 && top < scrollViewportOf(tester).size.height;
}

/// A scroll controller whose position counts the `animateTo` calls made on it.
///
/// The landing position alone cannot tell a correct retry from a widget that
/// interrupts its own reveal: two competing animations toward the same target
/// converge, and every geometry assertion passes (#233). These counters are
/// the only thing in the suite that can see the difference.
class _RecordingScrollController extends ScrollController {
  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _RecordingPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _RecordingPosition extends ScrollPositionWithSingleContext {
  _RecordingPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  /// Every `animateTo` issued on this position.
  int animateCalls = 0;

  /// The `animateTo` calls that began while an earlier one was still running.
  ///
  /// Counted at call time rather than from the returned futures: a widget that
  /// interrupts itself calls again while the first animation is still running,
  /// and the first future only completes a microtask after its activity is
  /// disposed — after the second call has already been made.
  int overlaps = 0;

  int _outstanding = 0;

  final List<VoidCallback> _listeners = [];

  /// The listeners attached to this position right now.
  int get listenerCount => _listeners.length;

  /// Whether anything is listening to [isScrollingNotifier].
  ///
  /// Read from here because `hasListeners` is protected to `ChangeNotifier`
  /// subclasses, which this position is.
  bool get isScrollingWatched => isScrollingNotifier.hasListeners;

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    super.removeListener(listener);
  }

  @override
  Future<void> animateTo(
    double to, {
    required Duration duration,
    required Curve curve,
  }) {
    animateCalls++;
    if (_outstanding > 0) overlaps++;
    _outstanding++;
    return super
        .animateTo(to, duration: duration, curve: curve)
        .whenComplete(() => _outstanding--);
  }
}

/// Mounts a banner below the fold of a page sitting at offset 0, and starts
/// its reveal animation's clock.
///
/// The interruption cases below go on from here: they let the animation run
/// for a stated time, then do something to the page while it is in flight.
///
/// Two frames, not one. The first lays the banner out, and its post-frame
/// callback starts the animation. A ticker started there takes its start time
/// from its first tick, so the frame after that is the animation at zero
/// elapsed, whatever time the pump advanced. Without the second frame a
/// `pump(40ms)` lands where a `pump(4ms)` does — the scroll is still at 0 —
/// and an early and a late interruption are the same test. With it, the
/// offsets match #233's measurements: 354 at 4ms, 1000 at 40ms.
///
/// [startClock] false stops after the first frame, for the one case that
/// wants the page still at rest when the interruption comes.
Future<(ValueNotifier<String?>, _RecordingScrollController)> _startReveal(
  WidgetTester tester, {
  bool startClock = true,
  double textScale = 1,
  String message = 'That address is not a BGE server.',
  bool keyboardFocus = false,
}) async {
  _useNarrowWindow(tester);
  final notifier = ValueNotifier<String?>(null);
  addTearDown(notifier.dispose);
  final recording = _RecordingScrollController();
  addTearDown(recording.dispose);

  await tester.pumpWidget(
    _revealHost(
      message: notifier,
      controller: recording,
      bannerAboveFiller: false,
      textScale: textScale,
      keyboardFocus: keyboardFocus,
    ),
  );
  notifier.value = message;
  await tester.pump();
  if (startClock) await tester.pump();
  return (notifier, recording);
}

/// The events refresh banner's copy, which #452's measurements used.
const _refreshCopy =
    "Couldn't refresh your events. What's shown may be out of date.";

/// The refresh banners' action at rest.
Widget _tryAgain() => TextButton.icon(
  onPressed: () {},
  icon: const Icon(Icons.refresh),
  label: const Text('Try again'),
);

/// The same action while a refresh runs: disabled, with a spinner and a
/// longer label. Pump with `pump()`, never `pumpAndSettle`: the spinner never
/// settles.
Widget _refreshing() => TextButton.icon(
  onPressed: null,
  icon: SizedBox.square(
    dimension: BgeTokens.standard.spaceMd,
    child: const CircularProgressIndicator(strokeWidth: 2),
  ),
  label: const Text('Refreshing…'),
);

/// Hosts a banner carrying [action] the way a page does: in a scroll view,
/// inset by `BgePage`'s horizontal padding, in a window [width] wide at
/// [textScale].
Future<void> _actionHost(
  WidgetTester tester, {
  required double width,
  required double textScale,
  required Widget action,
  TextDirection dir = TextDirection.ltr,
}) async {
  useViewSize(tester, Size(width, 800));
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        theme: BgeTheme.light(),
        home: Directionality(
          textDirection: dir,
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: BgeTokens.standard.spaceLg,
                ),
                child: BgeInlineBanner(
                  tone: BgeBannerTone.warning,
                  reveal: false,
                  message: _refreshCopy,
                  action: action,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The banner's message: its icon and text, without the action. The merged
/// semantics node wraps exactly that.
Rect _messageRect(WidgetTester tester, {String text = _refreshCopy}) =>
    tester.getRect(
      find
          .ancestor(of: find.text(text), matching: find.byType(MergeSemantics))
          .first,
    );

/// Whether [action] sits below the message rather than beside it.
bool _stacked(
  WidgetTester tester,
  Finder action, {
  String text = _refreshCopy,
}) => tester.getRect(action).top >= _messageRect(tester, text: text).bottom;

/// The body text's font size, as the banner reads it from the theme.
double _bodyFontSize(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(BgeInlineBanner)))
        .textTheme
        .bodyMedium!
        .fontSize!;

/// #452's rule: [action] is below the message, or the message's text keeps
/// at least [BgeInlineBanner.minMessageWidthEms] ems beside it.
///
/// No exception is not enough: the common failure on a device is the
/// squeeze, which throws nothing.
void _expectMessageHasRoom(
  WidgetTester tester,
  Finder action, {
  required double textScale,
}) {
  if (_stacked(tester, action)) return;
  final textWidth =
      _messageRect(tester).width -
      BgeTokens.standard.spaceLg -
      BgeTokens.standard.spaceMd;
  expect(
    textWidth,
    greaterThanOrEqualTo(
      BgeInlineBanner.minMessageWidthEms * textScale * _bodyFontSize(tester),
    ),
    reason: 'beside the action, the text has to keep a usable width',
  );
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

    testWidgets('a stacked action stays its own node, outside the announcing '
        'message (#452)', (tester) async {
      // The case above has the action beside the message. Below it, the
      // action is still the layout's second child rather than part of the
      // message, so the message keeps its one announcing node and the
      // action its own.
      final handle = tester.ensureSemantics();
      await _actionHost(tester, width: 320, textScale: 2, action: _tryAgain());
      expect(
        _stacked(tester, find.byType(TextButton)),
        isTrue,
        reason: 'sanity: stacked',
      );

      final message = tester.getSemantics(find.text(_refreshCopy));
      expect(
        message.flagsCollection.isLiveRegion,
        isTrue,
        reason: 'the message still announces itself',
      );
      expect(message.label, isNot(contains('Try again')));

      final button = tester.getSemantics(find.text('Try again'));
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

    // Under `flutter test`'s font every glyph is one em wide, so the 'Try
    // again' button is about 184dp at 1.0 and stacks even at 412dp, while a
    // 48dp IconButton fits beside. Real fonts are narrower (#452's 2026-10-23
    // table): a rule that measures its children behaves the same under both.
    const states = {'at rest': _tryAgain, 'refreshing': _refreshing};
    for (final width in const [320, 360, 412]) {
      for (final scale in const [1.0, 1.5, 2.0]) {
        for (final MapEntry(key: state, value: build) in states.entries) {
          testWidgets(
            'an action leaves the message room at ${width}dp, ${scale}x, '
            '$state (#452)',
            (tester) async {
              await _actionHost(
                tester,
                width: width.toDouble(),
                textScale: scale,
                action: build(),
              );

              expect(tester.takeException(), isNull);
              final banner = tester.getRect(find.byType(BgeInlineBanner));
              final action = tester.getRect(find.byType(TextButton));
              expect(
                banner.contains(action.topLeft) &&
                    banner.contains(action.bottomRight - const Offset(1, 1)),
                isTrue,
                reason: 'the action has to stay inside the banner',
              );
              _expectMessageHasRoom(
                tester,
                find.byType(TextButton),
                textScale: scale,
              );
            },
          );
        }
      }
    }

    testWidgets('a narrow action stays beside the message where there is '
        'room', (tester) async {
      await _actionHost(
        tester,
        width: 412,
        textScale: 1,
        action: IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
      );

      expect(_stacked(tester, find.byType(IconButton)), isFalse);
    });

    testWidgets('the threshold grows with the text scale (#452)', (
      tester,
    ) async {
      // A 48dp IconButton at 412dp leaves the message 276dp. The threshold is
      // the icon and its gap plus ten ems of the body text as drawn: 250dp at
      // 1.5, so the action stays beside, and 320dp at 2.0, so it stacks. A
      // threshold in dp, which #452 rejected, allows 140dp of text at every
      // scale, only five ems at 2.0, and keeps the action beside at both.
      for (final (scale, stacks) in const [(1.5, false), (2.0, true)]) {
        await _actionHost(
          tester,
          width: 412,
          textScale: scale,
          action: IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
        );

        expect(tester.takeException(), isNull);
        expect(
          _stacked(tester, find.byType(IconButton)),
          stacks,
          reason: '${scale}x',
        );
      }
    });

    testWidgets('stacks the action below, at the end edge, when the message '
        'would be squeezed', (tester) async {
      await _actionHost(tester, width: 320, textScale: 2, action: _tryAgain());

      expect(tester.takeException(), isNull);
      expect(_stacked(tester, find.byType(TextButton)), isTrue);
      final banner = tester.getRect(find.byType(BgeInlineBanner));
      final action = tester.getRect(find.byType(TextButton));
      expect(
        action.right,
        moreOrLessEquals(
          banner.right - BgeTokens.standard.spaceMd,
          epsilon: 0.5,
        ),
      );
    });

    testWidgets('in RTL the action keeps to the end edge in both '
        'arrangements', (tester) async {
      await _actionHost(
        tester,
        width: 320,
        textScale: 2,
        action: _tryAgain(),
        dir: TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
      expect(
        _stacked(tester, find.byType(TextButton)),
        isTrue,
        reason: 'sanity: stacked',
      );
      var banner = tester.getRect(find.byType(BgeInlineBanner));
      final stacked = tester.getRect(find.byType(TextButton));
      expect(
        stacked.left,
        moreOrLessEquals(
          banner.left + BgeTokens.standard.spaceMd,
          epsilon: 0.5,
        ),
        reason: 'below the message, at the left end',
      );

      await _actionHost(
        tester,
        width: 412,
        textScale: 1,
        action: IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
        dir: TextDirection.rtl,
      );
      expect(
        _stacked(tester, find.byType(IconButton)),
        isFalse,
        reason: 'sanity: beside',
      );
      banner = tester.getRect(find.byType(BgeInlineBanner));
      final beside = tester.getRect(find.byType(IconButton));
      expect(
        beside.left,
        moreOrLessEquals(
          banner.left + BgeTokens.standard.spaceMd,
          epsilon: 0.5,
        ),
      );
      expect(
        beside.right,
        lessThanOrEqualTo(_messageRect(tester).left),
        reason: 'beside the message, to its left',
      );
    });

    testWidgets('a two-button action wraps inside the banner at 320dp and '
        '2.0', (tester) async {
      // The invite inbox's action, the widest one passed today.
      await _actionHost(
        tester,
        width: 320,
        textScale: 2,
        action: Wrap(
          children: [
            TextButton(onPressed: () {}, child: const Text('Open household')),
            TextButton(onPressed: () {}, child: const Text('Dismiss')),
          ],
        ),
      );

      expect(tester.takeException(), isNull);
      final banner = tester.getRect(find.byType(BgeInlineBanner));
      for (final button in find.byType(TextButton).evaluate()) {
        final rect = tester.getRect(find.byWidget(button.widget));
        expect(
          banner.contains(rect.topLeft) &&
              banner.contains(rect.bottomRight - const Offset(1, 1)),
          isTrue,
          reason: '${button.widget} has to stay inside the banner',
        );
      }
      _expectMessageHasRoom(tester, find.byType(Wrap), textScale: 2);
    });

    testWidgets('a focused action keeps focus when its label change flips '
        'the layout', (tester) async {
      // #452's focus trap. A label change flips the layout, and the button's
      // element, its state and its focus all survive it. The button stays
      // enabled throughout. Pressing a refresh banner's retry disables it,
      // and a disabled button drops focus whatever the layout does: that
      // loss belongs to the call site, not to the banner.
      final label = ValueNotifier<String>('Go');
      addTearDown(label.dispose);
      final node = FocusNode();
      addTearDown(node.dispose);

      await _actionHost(
        tester,
        width: 412,
        textScale: 1,
        action: ValueListenableBuilder<String>(
          valueListenable: label,
          builder: (context, value, _) =>
              TextButton(focusNode: node, onPressed: () {}, child: Text(value)),
        ),
      );
      expect(
        _stacked(tester, find.byType(TextButton)),
        isFalse,
        reason: 'sanity: starts beside',
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue, reason: 'sanity: focused');
      final button = tester.state(find.byType(TextButton));

      label.value = 'Refreshing your events…';
      await tester.pump();

      expect(
        _stacked(tester, find.byType(TextButton)),
        isTrue,
        reason: 'sanity: the label change flipped the layout',
      );
      expect(node.hasFocus, isTrue);
      // Focus alone can't catch a rebuilt button here. A node passed in from
      // outside re-attaches to the new element and keeps focus: measured,
      // swapping a Row for a Column kept it. The call sites pass no node, and
      // a button's own node goes with its state. So the state has to survive.
      expect(
        tester.state(find.byType(TextButton)),
        same(button),
        reason: 'the flip must not rebuild the button',
      );
    });

    testWidgets('reports intrinsic widths from its children', (tester) async {
      // An AlertDialog sizes its content with IntrinsicWidth. RenderBox's
      // defaults report zero, and the banner would collapse.
      useViewSize(tester, const Size(412, 800));
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: Scaffold(
            body: Center(
              child: IntrinsicWidth(
                child: BgeInlineBanner(
                  tone: BgeBannerTone.warning,
                  reveal: false,
                  message: _refreshCopy,
                  action: _tryAgain(),
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      // Sized to its max intrinsic width, the layout has to have room for at
      // least the message at its threshold. With RenderBox's zero defaults
      // the banner is its padding alone, and the layout inside it 0dp wide.
      final layout = tester.renderObject<RenderBannerActionLayout>(
        find.byType(BannerActionLayout),
      );
      expect(layout.size.width, greaterThanOrEqualTo(layout.minMessageWidth));
    });

    testWidgets('at its max intrinsic width a short message keeps its action '
        'beside it', (tester) async {
      // The max intrinsic width is the width past which more width never
      // makes the banner shorter. A message narrower than the threshold must
      // not report a width at which the action stacks, or a parent sizing
      // the banner to it would get the taller arrangement.
      //
      // 1.01 as well as 1.0: at a fractional scale the widths are fractional,
      // and adding them up and taking them away again can land a hair under
      // the threshold. Measured without a tolerance for it, 42 of 201 scales
      // from 1.0 to 3.0 stacked here.
      const short = 'Offline.';
      useViewSize(tester, const Size(800, 800));
      for (final scale in const [1.0, 1.01]) {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: MaterialApp(
              theme: BgeTheme.light(),
              home: Scaffold(
                body: Center(
                  child: IntrinsicWidth(
                    child: BgeInlineBanner(
                      tone: BgeBannerTone.warning,
                      reveal: false,
                      message: short,
                      action: _tryAgain(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        expect(
          _stacked(tester, find.byType(TextButton), text: short),
          isFalse,
          reason: '${scale}x',
        );
      }
    });

    testWidgets('dry layout matches layout', (tester) async {
      // A Wrap or a dialog can size the banner by dry layout. RenderBox's
      // default reports zero. Checked in both arrangements.
      final cases = {
        'stacked': (_tryAgain(), find.byType(TextButton)),
        'beside': (
          IconButton(onPressed: () {}, icon: const Icon(Icons.close)),
          find.byType(IconButton),
        ),
      };
      for (final MapEntry(key: arrangement, value: (action, finder))
          in cases.entries) {
        await _actionHost(tester, width: 412, textScale: 1, action: action);
        expect(
          _stacked(tester, finder),
          arrangement == 'stacked',
          reason: 'sanity: $arrangement',
        );

        final box = tester.renderObject<RenderBox>(
          find.byType(BannerActionLayout),
        );
        expect(
          box.getDryLayout(box.constraints),
          box.size,
          reason: arrangement,
        );
      }
    });

    testWidgets('reports its message baseline, laid out and dry', (
      tester,
    ) async {
      // The Row this layout replaced reported one. Without it a
      // baseline-aligned parent drops the banner to the top, and asking for
      // the dry baseline asserts.
      useViewSize(tester, const Size(412, 800));
      const row = Key('row');
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: Scaffold(
            body: Row(
              key: row,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text('Label'),
                Expanded(
                  child: BgeInlineBanner(
                    tone: BgeBannerTone.warning,
                    reveal: false,
                    message: _refreshCopy,
                    action: _tryAgain(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.text('Label')).top,
        moreOrLessEquals(tester.getRect(find.text(_refreshCopy)).top),
        reason: "the label lines up with the message's first line",
      );
      final box = tester.renderObject<RenderBox>(find.byKey(row));
      expect(box.getDryLayout(box.constraints), box.size);
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

    testWidgets('a tap early in the reveal does not strand the banner (#233)', (
      tester,
    ) async {
      // A bare tap anywhere in the scroll view cuts the reveal short: the drag
      // recognizer's pointer-down holds the position, and holding it disposes
      // the running animation. Early enough, the banner is left below the
      // fold — an outcome the user is never shown, which is #209 again.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 4));

      await tester.tapAt(const Offset(160, 240));
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        reason: 'nothing about a tap means "leave me where I am"',
      );
      expect(
        pos.animateCalls,
        2,
        reason: 'the reveal, then exactly one retry once the finger lifts',
      );
      expect(
        pos.overlaps,
        0,
        reason: 'the retry must not start while the first animation runs',
      );
    });

    testWidgets('a tap late in the reveal does not leave the banner short '
        '(#233)', (tester) async {
      // Late enough that the banner's top is on screen, but a banner taller
      // than what is left below it is still cut off: the start of the
      // message shows and the end of it does not. At 200% text a real error
      // string does that — the shape #233's canary on create-household has.
      final (_, recording) = await _startReveal(
        tester,
        textScale: 2,
        message:
            'Plain http is only allowed for local and private network '
            'addresses. Use https for this server.',
      );
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 40));
      final top = _bannerTop(tester);
      expect(
        top,
        greaterThan(BgeTokens.standard.spaceMd + 1),
        reason: 'sanity: the reveal is still travelling when the tap lands',
      );
      expect(
        top + tester.getSize(find.byType(BgeInlineBanner)).height,
        greaterThan(scrollViewportOf(tester).size.height),
        reason: 'sanity: the tap has to leave the banner unreadable',
      );

      await tester.tapAt(const Offset(160, 240));
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
      expect(pos.animateCalls, 2);
      expect(pos.overlaps, 0);
    });

    testWidgets('a late tap that leaves the banner readable does not move it '
        'again', (tester) async {
      // The retry goes back through the same visibility check as any reveal
      // (#233), so it never moves a viewport that was fine. A banner the tap
      // froze wholly on screen is read where it stands.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 40));
      final top = _bannerTop(tester);
      expect(
        top >= 0 &&
            top + tester.getSize(find.byType(BgeInlineBanner)).height <=
                scrollViewportOf(tester).size.height,
        isTrue,
        reason: 'sanity: the whole banner is on screen when the tap lands',
      );

      await tester.tapAt(const Offset(160, 240));
      final frozen = _bannerTop(tester);
      await tester.pumpAndSettle();

      expect(pos.animateCalls, 1);
      expect(_bannerTop(tester), moreOrLessEquals(frozen, epsilon: 0.5));
    });

    testWidgets('a drag during the reveal leaves the user where they scrolled '
        'to', (tester) async {
      // The other half of the split. A drag is the user deliberately scrolling
      // elsewhere, and retrying after it would fight them — the behaviour the
      // gesture guard exists to prevent. Pinned so a retry on every
      // interruption cannot quietly replace the tap-only one.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 4));

      final drag = await tester.startGesture(const Offset(160, 240));
      for (var i = 0; i < 3; i++) {
        await drag.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pumpAndSettle();

      expect(pos.animateCalls, 1, reason: 'a drag is not retried');
      expect(_bannerTopVisible(tester), isFalse);
    });

    testWidgets('a drag into the edge the page rests on is not retried', (
      tester,
    ) async {
      // Touched before the animation has moved the page, then dragged toward
      // the top it is already at. The page does not move — it is overscroll —
      // so nothing that waits for the page to move sees a drag at all. It is
      // still the user saying where they want to be.
      final (_, recording) = await _startReveal(tester, startClock: false);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 4));
      expect(recording.offset, 0, reason: 'sanity: the page is still at rest');

      final drag = await tester.startGesture(const Offset(160, 240));
      for (var i = 0; i < 3; i++) {
        await drag.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pumpAndSettle();

      expect(pos.animateCalls, 1, reason: 'a drag is not retried');
      expect(_bannerTopVisible(tester), isFalse);
    });

    testWidgets('a mouse-wheel scroll during the reveal leaves the user where '
        'they scrolled to', (tester) async {
      // A wheel tick is a user scroll as much as a drag is, but it is over
      // within the one event: the position takes the direction, moves, goes
      // idle and drops the direction again before the reveal's future even
      // completes. Only something already watching while the reveal runs can
      // see it.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 40));

      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(160, 240),
          scrollDelta: Offset(0, -300),
        ),
      );
      final scrolledTo = recording.offset;
      await tester.pumpAndSettle();

      expect(pos.animateCalls, 1, reason: 'a wheel scroll is not retried');
      expect(recording.offset, scrolledTo);
    });

    testWidgets('a keyboard scroll during the reveal leaves the user where '
        'they scrolled to', (tester) async {
      // PageUp scrolls with `moveTo`, which leaves the direction idle, so to
      // the position it is a programmatic scroll like the one that follows a
      // tap on a field, and that one is retried. Only the key itself says
      // the user did it.
      final (_, recording) = await _startReveal(tester, keyboardFocus: true);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 40));

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();

      expect(
        pos.animateCalls,
        2,
        reason: "the reveal and the key's own scroll; a retry would be a third",
      );
      expect(_bannerTopVisible(tester), isFalse);
    });

    testWidgets('a reveal superseded by a copy change does not retry under a '
        'held finger', (tester) async {
      // A copy change mid-animation starts a second reveal, which cuts the
      // first one short. That shortfall is the widget's own doing, not an
      // interaction, and only the current reveal's completion may arm a watch.
      //
      // A regression pin, not proof of that guard. The settle check's
      // one-frame wait already sees a pointer-down's hold turn into a drag,
      // and with the guard removed this case still passes. What it pins is
      // the outcome the guard defends: the page follows the finger, and
      // nothing is retried.
      //
      // The copy changes early, while the banner is still below the fold. By
      // 40ms this banner is wholly on screen, and a copy change then finds it
      // readable and starts no second reveal at all.
      final (message, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 4));

      message.value = 'A different failure.';
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(pos.animateCalls, 2, reason: 'sanity: a second reveal started');

      final drag = await tester.startGesture(const Offset(160, 240));
      await tester.pump();
      await drag.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
      final held = recording.offset;
      await drag.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        recording.offset,
        moreOrLessEquals(held - 40, epsilon: 1),
        reason: 'the page must still follow the finger',
      );

      await drag.up();
      await tester.pumpAndSettle();
      expect(pos.animateCalls, 2);
    });

    testWidgets('a touch during a programmatic scroll that cut the reveal '
        'short is not retried under the finger', (tester) async {
      // A programmatic scroll — focusing a field scrolls it into view — cuts
      // the reveal short, and the retry waits for it to land. The user
      // touches before it does. That pointer-down's hold stops the scroll for
      // an instant before the drag takes over, and the instant reads exactly
      // like the scroll ending: a retry decided there starts under the finger
      // and takes the page out from under it.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 40));

      unawaited(
        recording.animateTo(
          100,
          duration: const Duration(milliseconds: 300),
          curve: Curves.linear,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _bannerTopVisible(tester),
        isFalse,
        reason:
            'sanity: a banner readable at the touch would not be moved, '
            'retry or not',
      );

      final drag = await tester.startGesture(const Offset(160, 240));
      await tester.pump();
      await drag.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));
      final held = recording.offset;
      await drag.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        recording.offset,
        moreOrLessEquals(held - 40, epsilon: 1),
        reason: 'the page must still follow the finger',
      );

      await drag.up();
      await tester.pumpAndSettle();
      expect(
        pos.animateCalls,
        2,
        reason: 'the reveal and the programmatic scroll, and no retry',
      );
    });

    testWidgets('a jump during the reveal is retried once it lands', (
      tester,
    ) async {
      // A programmatic interruption that is already over by the time the
      // reveal's future completes, so the position never reports the end of
      // it. This is the case the settle check after the next frame exists for.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 40));

      recording.jumpTo(100);
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
      expect(pos.animateCalls, 2);
    });

    testWidgets('a programmatic scroll during the reveal is retried once it '
        'settles (#233)', (tester) async {
      // Focusing a field scrolls it into view, and a scroll that starts while
      // the reveal runs cuts the reveal short. Nothing about it means "leave
      // me where I am". Unlike a jump, it is still running when the reveal's
      // future completes, so the retry waits for the page to stop scrolling.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 40));

      unawaited(
        recording.position.animateTo(
          100,
          duration: const Duration(milliseconds: 100),
          curve: Curves.linear,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
      // The position counts this test's own `animateTo` too, and that call is
      // the one expected overlap: it starts while the reveal runs, which is
      // how it cuts the reveal short. The rest is what the banner issued.
      expect(
        pos.animateCalls - 1,
        2,
        reason:
            'the reveal, then one retry once the programmatic scroll '
            'settled',
      );
      expect(
        pos.overlaps - 1,
        0,
        reason: 'the retry must not start while the programmatic scroll runs',
      );
    });

    testWidgets('a long press during the reveal is retried after release', (
      tester,
    ) async {
      // A press that never moves is a tap held longer, not a drag: the
      // position reads as scrolling for as long as the finger is down, and
      // the retry waits for it to lift rather than giving up.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 4));

      final press = await tester.startGesture(const Offset(160, 240));
      await tester.pump(const Duration(milliseconds: 600));
      await press.up();
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
      expect(pos.animateCalls, 2);
      expect(pos.overlaps, 0);
    });

    testWidgets('an undisturbed reveal animates once', (tester) async {
      // The counterpart that gives the counters meaning: a reveal nothing
      // interrupts must not retry itself, or watch its own animation and
      // re-enter on it.
      final (_, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;

      await tester.pumpAndSettle();

      expect(pos.animateCalls, 1);
      expect(pos.overlaps, 0);
    });

    testWidgets('a banner removed during an interrupted reveal does not '
        'retry', (tester) async {
      // The failure cleared, or the route popped, while the finger that cut
      // the reveal short is still down. The retry is waiting on that finger,
      // and has to go with the banner rather than fire for a widget that is no
      // longer there — and so do its listeners, which would otherwise outlive
      // the banner on a scroll position that does not.
      final (message, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 4));

      final press = await tester.startGesture(const Offset(160, 240));
      expect(
        pos.isScrollingWatched,
        isTrue,
        reason: 'sanity: the retry is waiting on the finger',
      );
      final watching = pos.listenerCount;

      message.value = null;
      await tester.pump();
      expect(
        pos.listenerCount,
        watching - 1,
        reason: 'the latch on the page moving goes with the banner',
      );
      expect(
        pos.isScrollingWatched,
        isFalse,
        reason: 'and so does its wait for the finger to lift',
      );

      await press.up();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(pos.animateCalls, 1);
    });

    testWidgets('a new message while an interrupted reveal waits reveals '
        'once', (tester) async {
      // A copy change while the finger that cut the reveal short is still
      // down. The copy change's reveal does not wait for the finger: it starts
      // in the next frame, under the held finger, because the gesture guard
      // keys on the scroll direction and a finger that has not moved reads as
      // idle. That reveal replaces the watch on the interrupted one, so
      // lifting the finger retries nothing. One reveal for the new copy, not
      // one from the copy change and another from the retry.
      final (message, recording) = await _startReveal(tester);
      final pos = recording.position as _RecordingPosition;
      await tester.pump(const Duration(milliseconds: 4));

      final press = await tester.startGesture(const Offset(160, 240));
      message.value = 'A different failure.';
      await tester.pump();
      await press.up();
      await tester.pumpAndSettle();

      expect(
        _bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
      expect(pos.overlaps, 0);
      // The first reveal and the copy change's. A retry when the finger lifts
      // would be a third.
      expect(pos.animateCalls, 2);
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
        greaterThan(scrollViewportOf(tester).size.height),
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
