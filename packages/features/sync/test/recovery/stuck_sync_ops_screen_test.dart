import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sync_queue/l10n/sync_localizations.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockRecovery extends Mock implements SyncRecovery {}

const _ops = [
  StuckSyncOp(
    entryId: 'q1',
    kind: StuckSyncOpKind.addToCollection,
    subject: 'Brass',
  ),
  StuckSyncOp(entryId: 'q2', kind: StuckSyncOpKind.updateCollection),
  StuckSyncOp(
    entryId: 'q3',
    kind: StuckSyncOpKind.removeFromCollection,
    subject: 'Catan',
  ),
  StuckSyncOp(
    entryId: 'q4',
    kind: StuckSyncOpKind.createHousehold,
    subject: 'Smiths',
  ),
  StuckSyncOp(entryId: 'q5', kind: StuckSyncOpKind.unreadable),
];

/// The retry-or-discard screen (#190) over a mocked [SyncRecovery].
void main() {
  late _MockRecovery recovery;
  late StreamController<List<StuckSyncOp>> stuck;

  setUp(() {
    recovery = _MockRecovery();
    stuck = StreamController<List<StuckSyncOp>>.broadcast();
    when(() => recovery.watch()).thenAnswer((_) => stuck.stream);
    when(() => recovery.retry(any())).thenAnswer((_) async => true);
    when(() => recovery.discard(any())).thenAnswer((_) async {});
  });

  tearDown(() => unawaited(stuck.close()));

  Widget harness({TextScaler textScaler = TextScaler.noScaling}) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: SyncLocalizations.localizationsDelegates,
    supportedLocales: SyncLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: StuckSyncOpsScreen(recovery: recovery),
  );

  Future<void> show(WidgetTester tester, List<StuckSyncOp> ops) async {
    await tester.pumpWidget(harness());
    stuck.add(ops);
    await tester.pumpAndSettle();
  }

  testWidgets('describes each stuck op in plain words', (tester) async {
    await show(tester, _ops);

    for (final text in [
      'Add Brass to your collection',
      'Change a game in your collection',
      'Remove Catan from your collection',
      'Create the household “Smiths”',
      "A change this version of the app can't read",
    ]) {
      await tester.scrollUntilVisible(find.text(text), 100);
      expect(find.text(text), findsOneWidget);
    }
    expect(find.text("Couldn't sync"), findsNWidgets(_visibleRows(tester)));
  });

  testWidgets('tells a screen reader how many stuck ops there are, and '
      'numbers only them', (tester) async {
    await show(tester, _ops.take(2).toList());

    final scrollable = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scrollable.semanticChildCount, 2);
    // The list's own children are the rows alone, so its semantic indexes
    // agree with that count: the intro is not "item 1".
    final list = tester.widget<SliverList>(find.byType(SliverList));
    expect(list.delegate.estimatedChildCount, 2);
  });

  testWidgets('says when nothing is stuck', (tester) async {
    await show(tester, const []);

    expect(find.byKey(StuckSyncOpsScreen.emptyKey), findsOneWidget);
    expect(
      find.text("There's nothing here to retry or discard."),
      findsOneWidget,
    );
  });

  testWidgets('a read failure shows the error', (tester) async {
    await tester.pumpWidget(harness());
    stuck.addError(StateError('read failed'));
    await tester.pumpAndSettle();

    expect(find.byKey(StuckSyncOpsScreen.errorKey), findsOneWidget);
  });

  testWidgets('try again retries that op', (tester) async {
    await show(tester, _ops.take(1).toList());

    await tester.tap(find.byKey(StuckSyncOpsScreen.retryKey('q1')));
    await tester.pumpAndSettle();

    verify(() => recovery.retry('q1')).called(1);
  });

  testWidgets('while a retry runs, its button stays put, disabled and '
      'labelled', (tester) async {
    final sending = Completer<bool>();
    when(() => recovery.retry('q1')).thenAnswer((_) => sending.future);
    await show(tester, _ops.take(1).toList());

    await tester.tap(find.byKey(StuckSyncOpsScreen.retryKey('q1')));
    await tester.pump();

    final button = find.byKey(StuckSyncOpsScreen.retryKey('q1'));
    expect(button, findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(
      find.descendant(of: button, matching: find.text('Sending…')),
      findsOneWidget,
    );

    sending.complete(true);
    await tester.pumpAndSettle();
  });

  testWidgets('an unreadable op offers only a discard', (tester) async {
    await show(tester, [_ops.last]);

    expect(find.byKey(StuckSyncOpsScreen.retryKey('q5')), findsNothing);
    expect(find.byKey(StuckSyncOpsScreen.discardKey('q5')), findsOneWidget);
  });

  group('discard', () {
    testWidgets('asks first, and keeping it changes nothing', (tester) async {
      await show(tester, _ops.take(1).toList());

      await tester.tap(find.byKey(StuckSyncOpsScreen.discardKey('q1')));
      await tester.pumpAndSettle();

      expect(find.text('Discard this change?'), findsOneWidget);
      await tester.tap(find.text('Keep it'));
      await tester.pumpAndSettle();

      verifyNever(() => recovery.discard(any()));
      expect(find.text('Discard this change?'), findsNothing);
    });

    testWidgets('once confirmed, discards that op', (tester) async {
      await show(tester, _ops.take(1).toList());

      await tester.tap(find.byKey(StuckSyncOpsScreen.discardKey('q1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(StuckSyncOpsScreen.discardConfirmKey));
      await tester.pumpAndSettle();

      verify(() => recovery.discard('q1')).called(1);
    });

    const goesWithIt =
        "It won't be sent, and it's undone on this device. Any later "
        "changes to the same game that haven't synced are discarded with "
        "it. This can't be reversed.";
    const alone =
        "It won't be sent, and it's undone on this device. This can't be "
        'reversed.';
    for (final (entryId, body) in [
      ('q1', goesWithIt),
      ('q3', goesWithIt),
      ('q2', alone),
      ('q4', alone),
    ]) {
      testWidgets('for $entryId, says what goes with it', (tester) async {
        await show(tester, _ops);

        final discard = find.byKey(StuckSyncOpsScreen.discardKey(entryId));
        await tester.scrollUntilVisible(discard, 100);
        await tester.tap(discard);
        await tester.pumpAndSettle();

        expect(find.text(body), findsOneWidget);
      });
    }
  });

  testWidgets('an action that throws says so', (tester) async {
    when(() => recovery.retry('q1')).thenThrow(StateError('disposed'));
    await show(tester, _ops.take(1).toList());

    await tester.tap(find.byKey(StuckSyncOpsScreen.retryKey('q1')));
    await tester.pumpAndSettle();

    expect(find.byKey(StuckSyncOpsScreen.actionFailedKey), findsOneWidget);
  });

  testWidgets('a retry the server refuses again says so', (tester) async {
    when(() => recovery.retry('q1')).thenAnswer((_) async => false);
    await show(tester, _ops.take(1).toList());

    await tester.tap(find.byKey(StuckSyncOpsScreen.retryKey('q1')));
    await tester.pumpAndSettle();

    expect(find.byKey(StuckSyncOpsScreen.refusedAgainKey), findsOneWidget);
    expect(
      find.text(
        "The server still didn't accept that change. You can try again later "
        'or discard it.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(StuckSyncOpsScreen.actionFailedKey), findsNothing);
  });

  testWidgets('a row lays out at 200% text on a narrow window', (tester) async {
    useViewSize(tester, const Size(320, 800));
    await tester.pumpWidget(harness(textScaler: const TextScaler.linear(2)));
    stuck.add(_ops.take(1).toList());
    await tester.pumpAndSettle();

    final discard = find.byKey(StuckSyncOpsScreen.discardKey('q1'));
    await tester.scrollUntilVisible(discard, 100);

    expect(tester.takeException(), isNull);
    expect(find.byKey(StuckSyncOpsScreen.retryKey('q1')), findsOneWidget);
    expect(discard, findsOneWidget);
  });
}

/// How many rows are built, which is how many status lines to expect.
int _visibleRows(WidgetTester tester) => _ops
    .where(
      (op) => find
          .byKey(StuckSyncOpsScreen.rowKey(op.entryId))
          .evaluate()
          .isNotEmpty,
    )
    .length;
