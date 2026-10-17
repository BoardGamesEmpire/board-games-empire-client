import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:sync_queue/sync_queue.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockQueue extends Mock implements SyncQueueRepository {}

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

/// A parked add for the game [_title] names.
final _stuckAdd = SyncQueueEntry(
  id: 'q1',
  payload: const AddToCollectionOperation(
    localId: 'gc-1',
    platformGameId: 'pg-1',
    medium: 'Physical',
    quantity: 1,
  ).serialized,
  status: SyncStatus.failed,
  retryCount: SyncQueueEntry.maxRetries,
  createdAt: DateTime.utc(2026, 10),
);

const _title = 'Brass';
const _noticeCopy = "1 change couldn't be sent to the server.";

/// The #190 shell wiring through the real composition: the home notice and
/// its gate, the route it opens, and a discard reaching the session's
/// repository and the collection's refresher.
///
/// The screen's own behaviour is pinned in `sync_queue`. What only this file
/// can check is that the shell hands it what the session registered.
void main() {
  late _MockAppBootstrapCubit cubit;
  late _MockQueue queue;
  late _MockGameCollectionRepository collection;
  late List<SyncQueueEntry> stuck;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    stuck = [_stuckAdd];
    queue = _MockQueue();
    when(() => queue.watchStuckEntries())
        .thenAnswer((_) => Stream.value(stuck));
    when(() => queue.getEntry('q1')).thenAnswer((_) async => _stuckAdd);

    collection = _MockGameCollectionRepository();
    when(() => collection.titleOf('gc-1')).thenAnswer((_) async => _title);
    when(() => collection.discardQueuedOp('q1')).thenAnswer((_) async => true);
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    bool withSession = true,
    GameCollectionRefresher? refresher,
  }) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          syncQueueRepository: withSession ? queue : null,
          gameCollectionRepository: withSession ? collection : null,
          householdRepository: withSession ? _MockHouseholdRepository() : null,
          gameCollectionRefresher: refresher,
        ),
      ),
    );
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
  }

  group('the home notice', () {
    testWidgets('shows while something is stuck', (tester) async {
      await pumpHome(tester);

      expect(find.text(_noticeCopy), findsOneWidget);
    });

    testWidgets('shows nothing while nothing is stuck', (tester) async {
      stuck = [];
      await pumpHome(tester);

      expect(find.byKey(StuckSyncOpsNotice.bannerKey), findsNothing);
    });

    testWidgets('is absent without a user session', (tester) async {
      await pumpHome(tester, withSession: false);

      expect(find.byKey(StuckSyncOpsNotice.bannerKey), findsNothing);
    });
  });

  testWidgets('review opens the screen, which lists the stuck op', (
    tester,
  ) async {
    await pumpHome(tester);

    await tester.tap(find.byKey(StuckSyncOpsNotice.reviewKey));
    await tester.pumpAndSettle();

    expect(find.byType(StuckSyncOpsScreen), findsOneWidget);
    expect(find.text('Add $_title to your collection'), findsOneWidget);
  });

  testWidgets("a discard undoes through the session's repository and "
      "refreshes the collection", (tester) async {
    var refreshes = 0;
    await pumpHome(
      tester,
      refresher: GameCollectionRefresher(() async => refreshes++),
    );
    await tester.tap(find.byKey(StuckSyncOpsNotice.reviewKey));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(StuckSyncOpsScreen.discardKey('q1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(StuckSyncOpsScreen.discardConfirmKey));
    await tester.pumpAndSettle();

    verify(() => collection.discardQueuedOp('q1')).called(1);
    expect(refreshes, 1);
  });
}
