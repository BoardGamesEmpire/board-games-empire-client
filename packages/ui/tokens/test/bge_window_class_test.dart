import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

void main() {
  const tokens = BgeTokens.standard;

  group('BgeWindowClass.fromWidth', () {
    test('switches class at the default breakpoints', () {
      expect(BgeWindowClass.fromWidth(599.9, tokens), BgeWindowClass.compact);
      expect(BgeWindowClass.fromWidth(600, tokens), BgeWindowClass.medium);
      expect(BgeWindowClass.fromWidth(839.9, tokens), BgeWindowClass.medium);
      expect(BgeWindowClass.fromWidth(840, tokens), BgeWindowClass.expanded);
      expect(BgeWindowClass.fromWidth(2000, tokens), BgeWindowClass.expanded);
    });

    test('follows retuned breakpoints, not fixed numbers', () {
      final retuned = tokens.copyWith(
        breakpointMedium: 500,
        breakpointExpanded: 900,
      );
      expect(BgeWindowClass.fromWidth(550, retuned), BgeWindowClass.medium);
      expect(BgeWindowClass.fromWidth(880, retuned), BgeWindowClass.medium);
      expect(BgeWindowClass.fromWidth(900, retuned), BgeWindowClass.expanded);
    });
  });

  group('BgeWindowClass.minWidth', () {
    test('is 0, the medium breakpoint and the expanded breakpoint', () {
      expect(BgeWindowClass.compact.minWidth(tokens), 0);
      expect(BgeWindowClass.medium.minWidth(tokens), 600);
      expect(BgeWindowClass.expanded.minWidth(tokens), 840);
    });
  });

  group('BgeWindowClass.of', () {
    testWidgets('reads the window width from MediaQuery', (tester) async {
      BgeWindowClass? seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(700, 800)),
          child: Builder(
            builder: (context) {
              seen = BgeWindowClass.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen, BgeWindowClass.medium);
    });
  });
}
