import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  group('BgeStateSliver', () {
    testWidgets('state sliver fills the rest of a CustomScrollView and '
        'centres its child', (tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          home: const Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(height: 100, key: Key('head')),
                ),
                BgeStateSliver(
                  child: SizedBox(width: 40, height: 40, key: Key('c')),
                ),
              ],
            ),
          ),
        ),
      );

      final viewport = tester.getRect(find.byType(CustomScrollView));
      final head = tester.getRect(find.byKey(const Key('head')));
      final child = tester.getRect(find.byKey(const Key('c')));
      final rest = Rect.fromLTRB(
        viewport.left,
        head.bottom,
        viewport.right,
        viewport.bottom,
      );
      expect(child.center.dx, closeTo(rest.center.dx, 0.5));
      expect(child.center.dy, closeTo(rest.center.dy, 0.5));
    });
  });
}
