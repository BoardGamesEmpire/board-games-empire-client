import 'package:api_keys/api_keys.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import '../support/fixtures.dart';
import '../support/harness.dart';

void main() {
  final users = permission(
    'users:manage',
    description: 'Manage every user',
    riskLevel: RiskLevel.critical,
  );
  final settings = permission(
    'settings:manage',
    description: 'Change how this server is set up',
    riskLevel: RiskLevel.critical,
  );

  /// What the last question answered, or null while none has.
  bool? answer;

  setUp(() => answer = null);

  /// A page whose button asks about [critical].
  Future<void> ask(
    WidgetTester tester,
    List<GrantablePermission> critical,
  ) async {
    await pumpOnPage(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              answer = await showCriticalConfirm(context, critical),
          child: const Text('Ask'),
        ),
      ),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
  }

  group('showCriticalConfirm', () {
    testWidgets("lists each Critical permission's description, and says the "
        'server may ask for a sign-in', (tester) async {
      await ask(tester, [users, settings]);

      expect(find.text('Give this key Critical permissions?'), findsOneWidget);
      expect(
        find.text(
          'Anyone who gets hold of this key could do serious harm with it. '
          'It would be able to:',
        ),
        findsOneWidget,
      );
      expect(find.text('Manage every user'), findsOneWidget);
      expect(find.text('Change how this server is set up'), findsOneWidget);
      expect(
        find.text('The server may ask you to sign in again first.'),
        findsOneWidget,
      );
      // The slugs are not what a person reads.
      expect(find.textContaining('users:manage'), findsNothing);
      expect(answer, isNull);
    });

    testWidgets('Confirm answers true', (tester) async {
      await ask(tester, [users]);

      await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(answer, isTrue);
    });

    testWidgets('Cancel answers false', (tester) async {
      await ask(tester, [users]);

      await tester.tap(find.byKey(CriticalConfirmDialog.cancelKey));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(answer, isFalse);
    });

    testWidgets('a tap outside answers false', (tester) async {
      await ask(tester, [users]);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(answer, isFalse);
    });

    testWidgets('with no permission to name, it still asks', (tester) async {
      await ask(tester, const []);

      expect(find.text('Give this key Critical permissions?'), findsOneWidget);
      expect(
        find.text(
          'This key would have a Critical permission. Anyone who gets hold '
          'of it could do serious harm with it.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('The server may ask you to sign in again first.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(CriticalConfirmDialog.confirmKey));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });

    testWidgets('320dp at 2.0 lays out a long list without overflow, with '
        'both answers in reach', (tester) async {
      useViewSize(tester, const Size(320, 480));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await ask(tester, [
        users,
        settings,
        for (var i = 0; i < 6; i++)
          permission(
            'critical:$i',
            description: 'A Critical permission with a long description $i',
            riskLevel: RiskLevel.critical,
          ),
      ]);

      expect(tester.takeException(), isNull);
      final confirm = find.byKey(CriticalConfirmDialog.confirmKey);
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(confirm).bottom,
        lessThanOrEqualTo(480),
        reason: 'Confirm should be on screen once scrolled to',
      );
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(answer, isTrue);
    });
  });
}
