import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:sync_queue/l10n/sync_localizations.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockQueue extends Mock implements SyncQueueRepository {}

/// The notice that leads to the retry-or-discard screen (#190).
void main() {
  late StreamController<List<SyncQueueEntry>> stuck;
  late _MockQueue queue;
  late int reviews;

  setUp(() {
    stuck = StreamController<List<SyncQueueEntry>>.broadcast();
    queue = _MockQueue();
    when(() => queue.watchStuckEntries()).thenAnswer((_) => stuck.stream);
    reviews = 0;
  });

  tearDown(() => unawaited(stuck.close()));

  /// Reports [n] stuck entries.
  void report(int n) => stuck.add([
    for (var i = 0; i < n; i++)
      SyncQueueEntry(
        id: 'q$i',
        payload: '{}',
        status: SyncStatus.failed,
        retryCount: SyncQueueEntry.maxRetries,
        createdAt: DateTime.utc(2026, 10),
      ),
  ]);

  Widget harness() => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: SyncLocalizations.localizationsDelegates,
    supportedLocales: SyncLocalizations.supportedLocales,
    home: Scaffold(
      body: StuckSyncOpsNotice(queue: queue, onReview: (_) => reviews++),
    ),
  );

  testWidgets('shows nothing while nothing is stuck', (tester) async {
    await tester.pumpWidget(harness());
    report(0);
    await tester.pump();

    expect(find.byKey(StuckSyncOpsNotice.bannerKey), findsNothing);
  });

  testWidgets('counts what is stuck, and leads to the screen', (tester) async {
    await tester.pumpWidget(harness());
    report(2);
    await tester.pump();

    expect(
      find.text("2 changes couldn't be sent to the server."),
      findsOneWidget,
    );
    await tester.tap(find.byKey(StuckSyncOpsNotice.reviewKey));
    expect(reviews, 1);
  });

  testWidgets('goes once the last one is dealt with', (tester) async {
    await tester.pumpWidget(harness());
    report(1);
    await tester.pump();
    expect(find.text("1 change couldn't be sent to the server."), findsOne);

    report(0);
    await tester.pumpAndSettle();

    expect(find.byKey(StuckSyncOpsNotice.bannerKey), findsNothing);
  });
}
