import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:di/di.dart' show LocalClockService;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:game_collection/l10n/game_collection_localizations.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

const _userId = 'user-abc';
const _openKey = Key('test.open_entry');

/// Remove then re-add keeps play history (#46's re-scope), on the detail
/// over the real repository: the entry is removed from the screen, added
/// back, and the screen opened again shows the plays and the last played
/// date the server had recorded.
void main() {
  setUpAll(() {
    registerFallbackValue(
      const RemoveFromCollectionOperation(collectionId: 'fallback'),
    );
  });

  testWidgets('remove then re-add shows the play history kept', (tester) async {
    final db = inMemoryServerDatabase();
    final collection = GameCollectionRepositoryImpl(
      db: db,
      syncQueue: SyncQueueRepositoryImpl(
        db,
        const LocalClockService(),
        userId: _userId,
      ),
      currentUserId: _userId,
      clock: const LocalClockService(),
    );
    final sender = _MockSyncOperationSender();
    // The server can't be reached: each op stays queued, as offline.
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncNotClaimed());

    // As a hydrate brings it: the summary the row joins, then the entry with
    // the play history only server data carries (#258).
    await tester.runAsync(() async {
      await GameRepositoryImpl(db, userId: _userId).cachePlatformGameSummaries(
        const [
          PlatformGameSummary(
            id: 'pg-1',
            platformId: 'plat-1',
            platformName: 'Board game',
            game: GameSummary(id: 'g-1', title: 'Wingspan'),
          ),
        ],
      );
      await collection.mergeFromServer([
        GameCollection(
          id: 'gc-1',
          userId: _userId,
          platformGameId: 'pg-1',
          medium: GameMedium.physical,
          quantity: 2,
          playCount: 12,
          // Midday, so the local date is the 14th in any test time zone.
          lastPlayed: DateTime.utc(2026, 3, 14, 12),
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ], removalsSince: await collection.removalMark());
    });

    /// Lets drift's reads and writes, which run on real time, finish and
    /// reach the screen.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates:
            GameCollectionLocalizations.localizationsDelegates,
        supportedLocales: GameCollectionLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _openKey,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CollectionEntryScreen(
                    repository: collection,
                    sender: sender,
                    session: FakeSessionLease(),
                    entryId: 'gc-1',
                  ),
                ),
              ),
              child: const Text('The list beneath'),
            ),
          ),
        ),
      ),
    );

    Future<void> openEntry() async {
      await tester.tap(find.byKey(_openKey));
      await settle();
    }

    await openEntry();
    expect(find.text('12 plays'), findsOneWidget);

    await tester.tap(find.byKey(CollectionEntryScreen.removeKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(RemoveFromCollectionDialog.confirmKey));
    await settle();
    expect(find.byType(CollectionEntryScreen), findsNothing);
    expect(
      find.text(
        'Removed Wingspan on this device. It will sync when it '
        'can.',
      ),
      findsOneWidget,
    );

    final readded = await tester.runAsync(
      () => collection.addToCollection(
        platformGameId: 'pg-1',
        medium: GameMedium.physical,
      ),
    );
    // The removed row came back, under its id.
    expect(readded!.entry.id, 'gc-1');

    await openEntry();

    expect(find.byKey(CollectionEntryScreen.goneKey), findsNothing);
    expect(find.text('Wingspan'), findsOneWidget);
    expect(find.text('12 plays'), findsOneWidget);
    expect(find.text('Last played Mar 14, 2026'), findsOneWidget);
    // A re-add is a fresh ownership: its quantity, not the old one.
    expect(find.text('1 copy'), findsOneWidget);

    // Unmounted here, so the timer drift starts when its watch is let go
    // runs out before the test ends. Closed on the test's clock too: the
    // database's streams were opened on it, and a close awaited on real
    // time waits for them forever.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    unawaited(db.close());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
