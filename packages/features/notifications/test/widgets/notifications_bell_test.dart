import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifications/l10n/notifications_localizations_en.dart';
import 'package:notifications/notifications.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_notification_remote.dart';

final _l10n = NotificationsLocalizationsEn();

/// A count cubit that has read [unread] from the server, or read nothing
/// yet when [unread] is null. Its later reads answer [then], in order.
Future<NotificationCountCubit> _cubit(
  int? unread, {
  List<int> then = const [],
}) async {
  final cubit = NotificationCountCubit(
    FakeNotificationRemote()..scriptUnreadCounts([?unread, ...then]),
  );
  if (unread != null) {
    await cubit.refresh();
  }
  return cubit;
}

Future<void> _pumpBell(
  WidgetTester tester,
  NotificationCountCubit cubit, {
  VoidCallback? onPressed,
}) async {
  addTearDown(cubit.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: BgeTheme.light(),
      localizationsDelegates: NotificationsLocalizations.localizationsDelegates,
      supportedLocales: NotificationsLocalizations.supportedLocales,
      home: BlocProvider.value(
        value: cubit,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Home'),
            actions: [NotificationsBell(onPressed: onPressed ?? () {})],
          ),
        ),
      ),
    ),
  );
}

Badge _badge(WidgetTester tester) => tester.widget<Badge>(
  find.descendant(
    of: find.byType(NotificationsBell),
    matching: find.byType(Badge),
  ),
);

Finder _inBell(String text) => find.descendant(
  of: find.byType(NotificationsBell),
  matching: find.text(text),
);

/// The bell's one node: the button's.
SemanticsData _buttonNode(WidgetTester tester) => tester
    .getSemantics(find.byKey(NotificationsBell.buttonKey))
    .getSemanticsData();

void main() {
  testWidgets('no badge while the count is unknown or zero', (tester) async {
    for (final unread in [null, 0]) {
      await _pumpBell(tester, await _cubit(unread));

      expect(_badge(tester).isLabelVisible, isFalse, reason: 'at $unread');
      expect(_inBell('0'), findsNothing);
    }
  });

  testWidgets('shows 3', (tester) async {
    await _pumpBell(tester, await _cubit(3));

    expect(_badge(tester).isLabelVisible, isTrue);
    expect(_inBell('3'), findsOneWidget);
  });

  testWidgets('shows 99 at 99', (tester) async {
    await _pumpBell(tester, await _cubit(99));

    expect(_inBell('99'), findsOneWidget);
  });

  testWidgets('shows 99+ at 100 and at 250', (tester) async {
    for (final unread in [100, 250]) {
      await _pumpBell(tester, await _cubit(unread));

      expect(_inBell('99+'), findsOneWidget, reason: 'at $unread');
      expect(_inBell('$unread'), findsNothing);
    }
  });

  testWidgets('follows the count as it changes', (tester) async {
    // Marking all read reads the count again.
    final cubit = await _cubit(3, then: [0]);
    await _pumpBell(tester, cubit);

    cubit.allMarkedRead();
    await tester.pump();

    expect(_badge(tester).isLabelVisible, isFalse);
  });

  testWidgets('is named "Notifications, 3 unread"', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpBell(tester, await _cubit(3));

    expect(find.bySemanticsLabel('Notifications, 3 unread'), findsOneWidget);
    // The badge's own text adds nothing to the name.
    final node = _buttonNode(tester);
    expect(node.label, 'Notifications, 3 unread');
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  testWidgets('is named plain "Notifications" at zero and while unknown', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    for (final unread in [null, 0]) {
      await _pumpBell(tester, await _cubit(unread));

      expect(_buttonNode(tester).label, 'Notifications', reason: 'at $unread');
    }
    expect(_l10n.notificationsBellLabel(0), 'Notifications');
    expect(_l10n.notificationsBellLabel(1), 'Notifications, 1 unread');
    semantics.dispose();
  });

  testWidgets('is named "Notifications, 250 unread" while the badge shows '
      '99+', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpBell(tester, await _cubit(250));

    expect(_inBell('99+'), findsOneWidget);
    expect(find.bySemanticsLabel('Notifications, 250 unread'), findsOneWidget);
    expect(_buttonNode(tester).label, 'Notifications, 250 unread');
    semantics.dispose();
  });

  testWidgets('tooltip excluded from semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpBell(tester, await _cubit(3));

    // A pointer user still gets the tooltip.
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(NotificationsBell.buttonKey),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, _l10n.notificationsBellTooltip);
    expect(tooltip.excludeFromSemantics, isTrue);
    // The name is the label alone, never the tooltip field, so iOS reads it
    // once.
    expect(_buttonNode(tester).tooltip, isEmpty);
    semantics.dispose();
  });

  testWidgets('calls onPressed', (tester) async {
    var pressed = 0;
    await _pumpBell(tester, await _cubit(3), onPressed: () => pressed++);

    await tester.tap(find.byKey(NotificationsBell.buttonKey));
    expect(pressed, 1);
  });

  testWidgets('has a 48dp tap target', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpBell(tester, await _cubit(3));

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    expect(
      tester.getSize(find.byKey(NotificationsBell.buttonKey)),
      const Size.square(48),
    );
    semantics.dispose();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('at $scale text the badge never widens the bell, and stays '
        'inside it', (tester) async {
      useViewSize(tester, const Size(320, 640));
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpBell(tester, await _cubit(250));

      final button = tester.getRect(find.byKey(NotificationsBell.buttonKey));
      expect(button.size, const Size.square(48));
      final badge = tester.getRect(
        find.descendant(
          of: find.byType(Badge),
          matching: find.byType(Container),
        ),
      );
      expect(
        button.inflate(0.5).contains(badge.topLeft) &&
            button.inflate(0.5).contains(badge.bottomRight),
        isTrue,
        reason: 'the badge $badge reaches outside the bell $button',
      );
    });
  }
}
