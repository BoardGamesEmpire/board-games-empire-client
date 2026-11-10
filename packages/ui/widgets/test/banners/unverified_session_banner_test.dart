import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// #98: shell notice for a session restored without server confirmation.
void main() {
  const message = 'Offline — using your saved sign-in.';
  const dismiss = 'Dismiss';

  Widget host({required bool visible, VoidCallback? onDismiss}) => MaterialApp(
    home: Column(
      children: [
        UnverifiedSessionBanner(
          visible: visible,
          message: message,
          dismissLabel: dismiss,
          onDismiss: onDismiss ?? () {},
        ),
        const Expanded(child: SizedBox()),
      ],
    ),
  );

  testWidgets('renders nothing when not visible', (tester) async {
    await tester.pumpWidget(host(visible: false));

    expect(find.text(message), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('shows message and dismiss control when visible', (tester) async {
    await tester.pumpWidget(host(visible: true));
    await tester.pump();

    expect(find.text(message), findsOneWidget);
    expect(find.byTooltip(dismiss), findsOneWidget);
  });

  testWidgets('the message is a live region — appearance itself is the '
      'readout trigger (SemanticsService.announce is deprecated, and '
      'Android deprecated announcement events outright)', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(visible: true));
    await tester.pump();

    expect(
      tester.getSemantics(find.text(message)),
      matchesSemantics(label: message, isLiveRegion: true),
    );

    handle.dispose();
  });

  testWidgets('hidden leaves no live region in the tree — nothing for '
      'assistive tech to re-read', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(visible: false));
    await tester.pump();

    expect(find.text(message), findsNothing);
    expect(find.bySemanticsLabel(message), findsNothing);

    handle.dispose();
  });

  testWidgets('a new episode recreates the live-region node — appear, '
      'disappear, reappear', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(visible: true));
    await tester.pump();
    expect(find.bySemanticsLabel(message), findsOneWidget);

    await tester.pumpWidget(host(visible: false));
    await tester.pump();
    expect(find.bySemanticsLabel(message), findsNothing);

    await tester.pumpWidget(host(visible: true));
    await tester.pump();
    expect(
      tester.getSemantics(find.text(message)),
      matchesSemantics(label: message, isLiveRegion: true),
    );

    handle.dispose();
  });

  testWidgets('the dismiss control reports through onDismiss — hiding is '
      "the HOST's decision, expressed back through visible (dismissal and "
      'layout inset compensation must share an owner)', (tester) async {
    var dismissed = 0;
    await tester.pumpWidget(
      host(visible: true, onDismiss: () => dismissed += 1),
    );
    await tester.pump();

    await tester.tap(find.byTooltip(dismiss));
    await tester.pump();

    expect(dismissed, 1);
    // The banner itself does NOT self-hide: with visible still true it is
    // still rendered, awaiting the host's verdict.
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('the dismiss control is reachable and labelled for '
      'assistive tech', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(visible: true));
    await tester.pump();

    expect(find.bySemanticsLabel(dismiss), findsOneWidget);

    handle.dispose();
  });

  testWidgets('does not steal focus on appearance', (tester) async {
    final focusNode = FocusNode(debugLabel: 'field');
    addTearDown(focusNode.dispose);

    // Scaffold: TextField needs a Material ancestor, which the bare
    // MaterialApp home does not provide (the banner brings its own
    // Material, but that does not cover siblings).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              UnverifiedSessionBanner(
                visible: false,
                message: message,
                dismissLabel: dismiss,
                onDismiss: () {},
              ),
              TextField(focusNode: focusNode, autofocus: true),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              UnverifiedSessionBanner(
                visible: true,
                message: message,
                dismissLabel: dismiss,
                onDismiss: () {},
              ),
              TextField(focusNode: focusNode),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      focusNode.hasFocus,
      isTrue,
      reason: 'the banner informs; it must not interrupt',
    );
  });

  group("the dismiss control's focus ring (#644)", () {
    final boundary = GlobalKey();
    final themes = {
      'light': BgeTheme.light(),
      'dark': BgeTheme.dark(),
      'highContrastLight': BgeTheme.highContrastLight(),
      'highContrastDark': BgeTheme.highContrastDark(),
    };

    Future<void> showBanner(WidgetTester tester, ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: boundary,
            child: Column(
              children: [
                UnverifiedSessionBanner(
                  visible: true,
                  message: message,
                  dismissLabel: dismiss,
                  onDismiss: () {},
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }

    final dismissButton = find.byType(IconButton);

    BgeButtonFocusRingPainter ring(WidgetTester tester) => tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: dismissButton,
            matching: find.byType(CustomPaint),
          ),
        )
        .map((paint) => paint.foregroundPainter)
        .whereType<BgeButtonFocusRingPainter>()
        .single;

    for (final MapEntry(key: name, value: theme) in themes.entries) {
      final scheme = theme.colorScheme;

      testWidgets("$name: Tab rings the dismiss control in the banner's "
          "foreground, on the app's icon button shape, outside it", (
        tester,
      ) async {
        await showBanner(tester, theme);

        final painter = ring(tester);
        // The banner's own content colour, not the app's `primary`, which
        // `tertiaryContainer` was never solved against.
        expect(painter.color, scheme.onTertiaryContainer);
        expect(painter.placement, BgeButtonFocusRingPlacement.outside);
        expect(
          painter.shape,
          theme.iconButtonTheme.style!.shape!.resolve(const <WidgetState>{}),
        );
      });

      testWidgets('$name: the ring holds 3:1 against the banner, and under '
          'the focus overlay', (tester) async {
        await showBanner(tester, theme);
        final banner = tester
            .widget<Material>(
              find
                  .ancestor(of: dismissButton, matching: find.byType(Material))
                  .last,
            )
            .color!;
        expect(banner, scheme.tertiaryContainer);
        final color = ring(tester).color!;
        final overlay = tester
            .widget<InkWell>(
              find.descendant(
                of: dismissButton,
                matching: find.byType(InkWell),
              ),
            )
            .overlayColor!
            .resolve(const {WidgetState.focused})!;

        // Both sides of the outside ring are the banner; the gap keeps it off
        // the overlay inside the button, which is checked too in case the
        // placement ever moves inside.
        expect(Wcag.contrastRatio(color, banner), greaterThanOrEqualTo(3.0));
        expect(
          Wcag.contrastRatio(color, Color.alphaBlend(overlay, banner)),
          greaterThanOrEqualTo(3.0),
        );
      });
    }

    testWidgets('the ring can be seen, past a gap that shows the banner', (
      tester,
    ) async {
      // Dark is where the app's `primary` ring failed: 2.92:1 here.
      final theme = BgeTheme.dark();
      const tokens = BgeTokens.standard;
      await showBanner(tester, theme);
      final button = tester.getRect(
        find.descendant(of: dismissButton, matching: find.byType(Material)),
      );

      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      Future<Color> pixelAt(Offset point) async =>
          (await tester.runAsync(() async {
            final image = await render.toImage();
            final bytes = (await image.toByteData())!;
            final at = (point.dy.floor() * image.width + point.dx.floor()) * 4;
            image.dispose();
            return Color.fromARGB(
              bytes.getUint8(at + 3),
              bytes.getUint8(at),
              bytes.getUint8(at + 1),
              bytes.getUint8(at + 2),
            );
          }))!;

      expect(
        await pixelAt(
          Offset(
            button.left - tokens.focusRingGap - tokens.focusOutlineWidth / 2,
            button.center.dy,
          ),
        ),
        theme.colorScheme.onTertiaryContainer,
      );
      expect(
        await pixelAt(
          Offset(button.left - tokens.focusRingGap / 2, button.center.dy),
        ),
        theme.colorScheme.tertiaryContainer,
      );
    });
  });
}
