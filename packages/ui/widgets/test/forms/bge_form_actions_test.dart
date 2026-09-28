import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

const _actionKey = Key('action');
const _bannerKey = Key('banner');

Widget _actions({BgeFormFailure? failure}) => BgeFormActions(
  failure: failure,
  action: BgeSubmitButton(key: _actionKey, label: 'Save', onPressed: () {}),
);

void main() {
  group('BgeFormActions', () {
    testWidgets('with no failure, is the action alone', (tester) async {
      await tester.pumpWidget(hostAtSize(tester, _actions()));

      expect(find.byKey(_actionKey), findsOneWidget);
      expect(find.byType(BgeInlineBanner), findsNothing);
    });

    testWidgets('puts a failure directly above the action, one spacing step '
        'away and exactly as wide', (tester) async {
      // The parent does not stretch its children, as a Center does not, so
      // the width match has to come from the unit rather than the column it
      // happens to sit in.
      await tester.pumpWidget(
        hostAtSize(
          tester,
          Center(
            child: SizedBox(
              width: 300,
              child: Align(
                alignment: Alignment.topCenter,
                child: _actions(
                  failure: const BgeFormFailure(
                    key: _bannerKey,
                    title: null,
                    message: 'That did not work.',
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final banner = tester.getRect(find.byKey(_bannerKey));
      final action = tester.getRect(find.byKey(_actionKey));
      expect(action.top - banner.bottom, BgeTokens.standard.spaceMd);
      expect(banner.left, action.left);
      expect(banner.width, action.width);
    });

    testWidgets('titles a failure only when given a title', (tester) async {
      await tester.pumpWidget(
        hostAtSize(
          tester,
          _actions(
            failure: const BgeFormFailure(
              title: "Couldn't save",
              message: 'The server did not answer.',
            ),
          ),
        ),
      );
      expect(find.text("Couldn't save"), findsOneWidget);
      expect(find.text('The server did not answer.'), findsOneWidget);

      await tester.pumpWidget(
        hostAtSize(
          tester,
          _actions(
            failure: const BgeFormFailure(
              title: null,
              message: "Couldn't save your changes.",
            ),
          ),
        ),
      );
      expect(find.text("Couldn't save"), findsNothing);
      expect(find.text("Couldn't save your changes."), findsOneWidget);
    });

    testWidgets('treats its failure as an arriving outcome: announced, and '
        'scrolled into view', (tester) async {
      final failure = ValueNotifier<BgeFormFailure?>(null);
      addTearDown(failure.dispose);
      await tester.pumpWidget(
        hostAtSize(
          tester,
          size: const Size(320, 480),
          BgePage(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The fields of a long form, with the action below the fold.
                const SizedBox(height: 1200),
                ValueListenableBuilder(
                  valueListenable: failure,
                  builder: (context, value, _) => _actions(failure: value),
                ),
                // Room below, so the reveal is not stopped short by the end
                // of the scroll extent.
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );
      final handle = tester.ensureSemantics();

      failure.value = const BgeFormFailure(
        key: _bannerKey,
        title: null,
        message: 'That did not work.',
      );
      await tester.pumpAndSettle();

      expect(
        topInViewport(tester, find.byKey(_bannerKey)),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
      );
      expect(
        tester.getSemantics(find.text('That did not work.')),
        isSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });
  });
}
