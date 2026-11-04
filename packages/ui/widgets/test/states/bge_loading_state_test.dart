import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(Widget state) => MaterialApp(
  theme: BgeTheme.light(),
  home: Scaffold(body: Center(child: state)),
);

void main() {
  group('BgeLoadingState', () {
    testWidgets('loading announces its label once', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const BgeLoadingState(label: 'Loading your events')),
      );

      final node = tester.getSemantics(find.byType(CircularProgressIndicator));
      expect(
        node,
        isSemantics(isLiveRegion: true, label: 'Loading your events'),
      );
      expect(
        find.semantics.byLabel('Loading your events'),
        findsOneWidget,
        reason: 'one node carries the label',
      );
      handle.dispose();
    });

    testWidgets('the spinner is silent', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const BgeLoadingState(label: 'Loading')));

      expect(
        find.descendant(
          of: find.byType(BgeLoadingState),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      final node = tester.getSemantics(find.byType(BgeLoadingState));
      expect(node.getSemanticsData().label, 'Loading');
      expect(node.childrenCount, 0, reason: 'nothing under the label');
      handle.dispose();
    });

    testWidgets('fits 320dp at 200% text', (tester) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          const BgeLoadingState(label: 'Loading your events'),
          size: const Size(320, 640),
          textScale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
