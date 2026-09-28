import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Hosts [state] the way both call sites do: inside a vertically centred
/// [BgePage], under the app theme.
Widget _host(Widget state) => MaterialApp(
  theme: BgeTheme.light(),
  home: BgePage(centerVertically: true, child: state),
);

BgeErrorState _state({
  VoidCallback? onRetry,
  List<Widget> secondaryActions = const [],
}) => BgeErrorState(
  icon: Icons.cloud_off_outlined,
  title: "Can't reach Home BGE",
  body: 'Check your connection and try again.',
  retryLabel: 'Try again',
  onRetry: onRetry ?? () {},
  secondaryActions: secondaryActions,
);

void main() {
  group('BgeErrorState', () {
    testWidgets('shows the title, body and retry, and retry fires onRetry', (
      tester,
    ) async {
      var retried = 0;
      await tester.pumpWidget(_host(_state(onRetry: () => retried++)));

      expect(find.text("Can't reach Home BGE"), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      expect(retried, 1);
    });

    testWidgets('announces the title and body as one live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_state()));

      final title = tester.getSemantics(find.text("Can't reach Home BGE"));
      expect(
        title,
        isSemantics(
          isLiveRegion: true,
          label: "Can't reach Home BGE\nCheck your connection and try again.",
        ),
      );
      expect(
        tester.getSemantics(find.text('Check your connection and try again.')),
        same(title),
        reason: 'one announcement, not a title followed by a fragment',
      );
      handle.dispose();
    });

    testWidgets('focuses retry when it appears', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_state()));
      await tester.pump();

      expect(
        tester.getSemantics(find.text('Try again')),
        isSemantics(label: 'Try again', isButton: true, isFocused: true),
      );
      handle.dispose();
    });

    testWidgets('places secondary actions below retry', (tester) async {
      await tester.pumpWidget(
        _host(
          _state(
            secondaryActions: [
              OutlinedButton(
                onPressed: () {},
                child: const Text('Delete local data'),
              ),
            ],
          ),
        ),
      );

      final retry = tester.getRect(find.text('Try again'));
      final secondary = tester.getRect(find.text('Delete local data'));
      expect(secondary.top, greaterThan(retry.bottom));
    });

    testWidgets('sizes retry to its label rather than stretching it', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_state()));

      final retry = tester.getSize(find.byType(FilledButton)).width;
      final state = tester.getSize(find.byType(BgeErrorState)).width;
      expect(retry, lessThan(state));
    });

    testWidgets('retryKey identifies the retry button', (tester) async {
      const key = Key('retry');
      var retried = 0;
      await tester.pumpWidget(
        _host(
          BgeErrorState(
            icon: Icons.error_outline,
            title: 'Startup failed',
            body: 'Your data has not been changed.',
            retryLabel: 'Try again',
            onRetry: () => retried++,
            retryKey: key,
          ),
        ),
      );

      await tester.tap(find.byKey(key));
      expect(retried, 1);
    });

    testWidgets('a screen reader hears the announcement and retry, and '
        'nothing from the icon', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_state()));

      final labels = <String>[];
      void collect(SemanticsNode node) {
        final label = node.getSemanticsData().label;
        if (label.isNotEmpty) labels.add(label);
        node.visitChildren((child) {
          collect(child);
          return true;
        });
      }

      tester.binding.rootPipelineOwner.visitChildren((owner) {
        final root = owner.semanticsOwner?.rootSemanticsNode;
        if (root != null) collect(root);
      });
      expect(labels, [
        "Can't reach Home BGE\nCheck your connection and try again.",
        'Try again',
      ]);
      handle.dispose();
    });

    // Every platform, because desktop is where this can fail. Material pads
    // tap targets on mobile by default but shrink-wraps them on macOS,
    // Windows and Linux, so there only the theme makes 48dp hold.
    testWidgets(
      'retry and secondary actions keep the 48dp tap target the theme '
      'provides',
      (tester) async {
        await tester.pumpWidget(
          _host(
            _state(
              secondaryActions: [
                OutlinedButton(onPressed: () {}, child: const Text('Reset')),
              ],
            ),
          ),
        );

        for (final button in [FilledButton, OutlinedButton]) {
          final size = tester.getSize(find.byType(button));
          expect(size.height, greaterThanOrEqualTo(48), reason: '$button');
          expect(size.width, greaterThanOrEqualTo(48), reason: '$button');
        }
      },
      variant: TargetPlatformVariant.all(),
    );

    testWidgets('does not overflow at 320dp and 2.0 text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          BgePage(
            centerVertically: true,
            child: _state(
              secondaryActions: [
                OutlinedButton(
                  onPressed: () {},
                  child: const Text('Delete local data'),
                ),
              ],
            ),
          ),
          size: const Size(320, 640),
          textScale: 2,
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
