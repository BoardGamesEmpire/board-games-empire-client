import 'package:bge_test_support/widgets.dart';
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
  const _Content({required this.onFocusChange, required this.onMount});

  final ValueChanged<bool> onFocusChange;
  final VoidCallback onMount;

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
      child: InkWell(onTap: () {}, onFocusChange: widget.onFocusChange),
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
  Future<Rect> show(WidgetTester tester) async {
    await tester.pumpWidget(
      hostAtSize(
        tester,
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
                    builder: (context, onFocusChange) => _Content(
                      onFocusChange: onFocusChange,
                      onMount: () => mounts++,
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
  Future<Color> onTheRing(WidgetTester tester, Rect content) async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final (width, bytes) = (await tester.runAsync(() async {
      final image = await render.toImage();
      return (image.width, (await image.toByteData())!);
    }))!;
    final at = (content.center.dy.floor() * width + content.left.floor()) * 4;
    return Color.fromARGB(
      bytes.getUint8(at + 3),
      bytes.getUint8(at),
      bytes.getUint8(at + 1),
      bytes.getUint8(at + 2),
    );
  }

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
}
