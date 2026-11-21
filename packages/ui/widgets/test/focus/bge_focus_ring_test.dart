import 'package:bge_test_support/widgets.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _contentKey = Key('content');
const _otherKey = Key('other');

/// An opaque box with a tappable ink over it, counting its mounts.
class _Content extends StatefulWidget {
  const _Content({
    required this.onFocusChange,
    required this.onMount,
    this.focusNode,
    this.onTap,
  });

  final ValueChanged<bool> onFocusChange;
  final VoidCallback onMount;
  final FocusNode? focusNode;
  final VoidCallback? onTap;

  @override
  State<_Content> createState() => _ContentState();
}

class _ContentState extends State<_Content> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: _contentKey,
    width: 100,
    height: 60,
    child: ColoredBox(
      color: Colors.black,
      child: InkWell(
        focusNode: widget.focusNode,
        onTap: widget.onTap ?? () {},
        onFocusChange: widget.onFocusChange,
      ),
    ),
  );
}

/// A control to which focus can go, ringed or not, with content over which a
/// ring has to be drawn: a keyboard user has to find what has their focus.
void main() {
  final boundary = GlobalKey();
  final primary = BgeTheme.light().colorScheme.primary;
  var mounts = 0;

  setUp(() {
    mounts = 0;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
  });

  /// The ringed content at the top left, and another control after it.
  ///
  /// [onTap] is the content's, given a context under the navigator.
  Future<Rect> show(
    WidgetTester tester, {
    FocusNode? focusNode,
    void Function(BuildContext context)? onTap,
    Color? color,
    bool overPicture = false,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      hostAtSize(
        tester,
        builder: theme == null
            ? null
            : (context, child) => Theme(data: theme, child: child!),
        RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BgeFocusRing(
                    borderRadius: BorderRadius.zero,
                    color: color,
                    overPicture: overPicture,
                    builder: (context, onFocusChange) => _Content(
                      onFocusChange: onFocusChange,
                      onMount: () => mounts++,
                      focusNode: focusNode,
                      onTap: onTap == null ? null : () => onTap(context),
                    ),
                  ),
                  TextButton(
                    key: _otherKey,
                    onPressed: () {},
                    child: const Text('Other'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.getRect(find.byKey(_contentKey));
  }

  /// The colour drawn now just inside the content's left edge, halfway down.
  Future<Color> onTheRing(WidgetTester tester, Rect content) async =>
      (await capturePixels(tester, boundary))(
        Offset(content.left, content.center.dy),
      );

  Future<void> tab(WidgetTester tester) =>
      tester.sendKeyEvent(LogicalKeyboardKey.tab);

  testWidgets('keyboard focus rings the content at once, over it', (
    tester,
  ) async {
    final content = await show(tester);
    expect(await onTheRing(tester, content), Colors.black);

    await tab(tester);
    // One frame: a ring that fades in lags the focus, and ignores the
    // reduce-motion setting.
    await tester.pump();

    expect(
      await onTheRing(tester, content),
      primary,
      reason: 'the content is opaque, so the ring has to be drawn over it',
    );
  });

  testWidgets('the ring goes with the focus', (tester) async {
    final content = await show(tester);
    await tab(tester);
    await tester.pump();

    expect(await onTheRing(tester, content), primary);

    // On to the other control.
    await tab(tester);
    await tester.pump();

    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.ancestor(
        of: find.byWidget(focused.widget),
        matching: find.byKey(_otherKey),
      ),
      findsOneWidget,
    );
    expect(await onTheRing(tester, content), Colors.black);
  });

  testWidgets("a pointer's focus is not ringed", (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    final content = await show(tester);

    await tab(tester);
    await tester.pump();

    expect(await onTheRing(tester, content), Colors.black);
  });

  testWidgets('the ring goes when the highlight mode turns to touch', (
    tester,
  ) async {
    final content = await show(tester);
    await tab(tester);
    await tester.pump();
    expect(await onTheRing(tester, content), primary);

    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    await tester.pump();

    expect(await onTheRing(tester, content), Colors.black);
  });

  testWidgets('the ring claims no press on a margin inside it, ringed or '
      'not, and the content still takes its own', (tester) async {
    await tester.pumpWidget(
      hostAtSize(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: BgeFocusRing(
              borderRadius: BorderRadius.zero,
              builder: (context, onFocusChange) => Padding(
                padding: const EdgeInsets.all(8),
                child: _Content(
                  onFocusChange: onFocusChange,
                  onMount: () => mounts++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final content = tester.getRect(find.byKey(_contentKey));
    final ring = tester.renderObject<RenderBox>(find.byType(BgeFocusRing));
    // What a caller that sends a missed press on elsewhere, as the game
    // detail's chip tap target does, asks of it.
    bool claims(Offset at) =>
        ring.hitTest(BoxHitTestResult(), position: ring.globalToLocal(at));
    final margin = Offset(content.left - 4, content.center.dy);

    expect(claims(margin), isFalse);
    expect(claims(content.center), isTrue);

    await tab(tester);
    await tester.pump();
    expect(claims(margin), isFalse);
    expect(claims(content.center), isTrue);
  });

  testWidgets('the content keeps its state as the ring comes and goes', (
    tester,
  ) async {
    await show(tester);

    await tab(tester);
    await tester.pump();
    await tab(tester);
    await tester.pump();

    expect(mounts, 1);
  });

  testWidgets(
    'a mouse press anywhere hides the ring, and the next key press brings it '
    'back (#758)',
    (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      final content = await show(tester, focusNode: node);

      // On empty space: no control takes the press, or the focus.
      await tester.tapAt(const Offset(300, 600), kind: PointerDeviceKind.mouse);
      await tester.pump();
      // Focus that arrives with the hand on the mouse, as in code. Settled,
      // not one pump: the focus change lands in a microtask, and the ink
      // rebuilds for it in the frame after.
      node.requestFocus();
      await tester.pumpAndSettle();

      expect(node.hasPrimaryFocus, isTrue);
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      expect(await onTheRing(tester, content), Colors.black);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(await onTheRing(tester, content), primary, reason: 'a key press');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'focus handed back after a mouse press shows no ring',
    (tester) async {
      // Opened by keyboard, closed by mouse: the user's hand is on the mouse
      // when focus comes back, and the mouse never pressed this control.
      final node = FocusNode();
      addTearDown(node.dispose);
      final content = await show(
        tester,
        focusNode: node,
        onTap: (context) => showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Dialog'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
      await tab(tester);
      await tester.pump();
      expect(node.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('Close'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(node.hasPrimaryFocus, isTrue);
      expect(
        FocusManager.instance.highlightMode,
        FocusHighlightMode.traditional,
      );
      expect(await onTheRing(tester, content), Colors.black);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  group('color replaces primary', () {
    // A colour no theme's primary is, so the ring can only be the given one.
    const given = Color(0xFF00FF00);
    final themes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };
    for (final MapEntry(key: name, value: build) in themes.entries) {
      testWidgets(name, (tester) async {
        final theme = build();
        expect(theme.colorScheme.primary, isNot(given));
        final content = await show(tester, color: given, theme: theme);

        await tab(tester);
        await tester.pump();

        expect(await onTheRing(tester, content), given);
      });
    }
  });
  group('over a picture (#812)', () {
    final themes = {
      'light': BgeTheme.light,
      'dark': BgeTheme.dark,
      'highContrastLight': BgeTheme.highContrastLight,
      'highContrastDark': BgeTheme.highContrastDark,
    };

    for (final MapEntry(key: name, value: build) in themes.entries) {
      test('pictureTonesOf stands 9:1 apart in all four themes ($name)', () {
        final (outer, inner) = BgeFocusRing.pictureTonesOf(build().colorScheme);
        expect(
          Wcag.contrastRatio(outer, inner),
          greaterThanOrEqualTo(9),
          reason: 'one of two tones 9:1 apart stands 3:1 from any colour',
        );
      });

      testWidgets('the outer tone rings the edge and the inner lies just '
          'inside it ($name)', (tester) async {
        final theme = build();
        final (outer, inner) = BgeFocusRing.pictureTonesOf(theme.colorScheme);
        final content = await show(tester, overPicture: true, theme: theme);

        await tab(tester);
        await tester.pump();

        final pixels = await capturePixels(tester, boundary);
        final y = content.center.dy;
        expect(pixels(Offset(content.left + 1, y)), outer);
        expect(pixels(Offset(content.left + 3, y)), inner);
        expect(pixels(Offset(content.left + 5, y)), Colors.black);
      });
    }

    test('a ring over a picture takes no color', () {
      expect(
        () => BgeFocusRing(
          borderRadius: BorderRadius.zero,
          overPicture: true,
          color: const Color(0xFF00FF00),
          builder: (context, onFocusChange) => const SizedBox(),
        ),
        throwsAssertionError,
      );
    });

    testWidgets('a ring not over a picture draws one stroke, as before', (
      tester,
    ) async {
      final content = await show(tester);

      await tab(tester);
      await tester.pump();

      final pixels = await capturePixels(tester, boundary);
      final y = content.center.dy;
      expect(pixels(Offset(content.left + 1, y)), primary);
      expect(pixels(Offset(content.left + 3, y)), Colors.black);
    });
  });
}
