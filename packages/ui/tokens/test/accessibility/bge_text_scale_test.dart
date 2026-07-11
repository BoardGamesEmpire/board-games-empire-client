import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  Future<BuildContext> pumpWithScale(
    WidgetTester tester,
    double scaleFactor,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scaleFactor)),
        child: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  group('BgeTextScale', () {
    test('ceiling is the WCAG 1.4.4 200% target', () {
      expect(BgeTextScale.maxScaleFactor, 2.0);
    });

    testWidgets('clampedOf caps scaling above the ceiling', (tester) async {
      final context = await pumpWithScale(tester, 3.0);
      expect(BgeTextScale.clampedOf(context).scale(10), 20);
    });

    testWidgets('clampedOf leaves sub-ceiling scaling untouched', (
      tester,
    ) async {
      final context = await pumpWithScale(tester, 1.5);
      expect(BgeTextScale.clampedOf(context).scale(10), 15);
    });

    testWidgets('clampedOf is identity at 1.0', (tester) async {
      final context = await pumpWithScale(tester, 1.0);
      expect(BgeTextScale.clampedOf(context).scale(10), 10);
    });
  });
}
