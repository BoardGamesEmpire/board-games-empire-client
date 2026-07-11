import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  Future<BuildContext> pumpWithReducedMotion(
    WidgetTester tester, {
    required bool disableAnimations,
  }) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
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

  group('BgeMotion', () {
    testWidgets('durationOf passes the standard duration through when the '
        'OS does not request reduced motion', (tester) async {
      final context = await pumpWithReducedMotion(
        tester,
        disableAnimations: false,
      );

      expect(BgeMotion.reduceMotionOf(context), isFalse);
      expect(
        BgeMotion.durationOf(context, BgeTokens.standard.motionMedium),
        BgeTokens.standard.motionMedium,
      );
    });

    testWidgets('durationOf collapses to zero under OS reduced motion', (
      tester,
    ) async {
      final context = await pumpWithReducedMotion(
        tester,
        disableAnimations: true,
      );

      expect(BgeMotion.reduceMotionOf(context), isTrue);
      expect(
        BgeMotion.durationOf(context, BgeTokens.standard.motionMedium),
        Duration.zero,
      );
    });
  });
}
