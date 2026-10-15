import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

/// Counts passes without running any. What these tests check is who calls
/// the seam, not what it holds.
class _RecordingRehydrator implements SessionRehydrator {
  int passes = 0;

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {}

  @override
  Future<void> rehydrateStale() async => passes++;
}

GameCollectionListItem _item(String id) => GameCollectionListItem(
  entry: GameCollection(
    id: id,
    userId: 'u1',
    platformGameId: 'pg-$id',
    medium: GameMedium.physical,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  title: 'Catan',
  platformName: 'Board game',
);

/// The #44 shell wiring through the real composition: the drawer entry and
/// its gate, the route resolving the session's repository and status,
/// the retry reaching the collection's own refresher, and the entry trigger
/// reaching the session's rehydrator.
///
/// The screen's own behaviour is pinned in `game_collection`. What only this
/// file can check is that the screen is handed what the session registered,
/// and that a container without the optional parts still renders it.
void main() {
  late _MockAppBootstrapCubit cubit;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  /// Pumps home with a cache holding one entry. [withRepository] false is a
  /// signed-out session, where the user tier is gone. [failedPass] publishes
  /// a status whose last pass failed, which is where the banner and its
  /// retry live.
  Future<void> pumpHome(
    WidgetTester tester, {
    bool withRepository = true,
    bool failedPass = false,
    GameCollectionRefresher? refresher,
    SessionRehydrator? rehydrator,
  }) async {
    final repository = _MockGameCollectionRepository();
    when(repository.watchCollectionListItems).thenAnswer(
      (_) => Stream<List<GameCollectionListItem>>.value([_item('e-1')]),
    );

    GameCollectionHydrationStatus? status;
    if (failedPass) {
      status = GameCollectionHydrationStatus()
        ..started()
        ..finished(CollectionHydrateOutcome.failed);
      addTearDown(status.close);
    }

    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          gameCollectionRepository: withRepository ? repository : null,
          gameCollectionHydrationStatus: status,
          gameCollectionRefresher: refresher,
          sessionRehydrator: rehydrator,
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

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
  }

  Future<void> openTheList(WidgetTester tester) async {
    await openDrawer(tester);
    await tester.tap(find.byKey(HomeScreen.entryKey('collection')));
    await tester.pumpAndSettle();
  }

  group('the drawer entry (#44)', () {
    testWidgets('shows when the session has a collection repository', (
      tester,
    ) async {
      await pumpHome(tester);
      await openDrawer(tester);

      expect(find.byKey(HomeScreen.entryKey('collection')), findsOneWidget);
      expect(find.text('Collection'), findsOneWidget);
    });

    testWidgets('hides when there is no user session', (tester) async {
      // The repository lives in the user tier, which sign-out tears down.
      await pumpHome(tester, withRepository: false);
      await openDrawer(tester);

      expect(find.byKey(HomeScreen.entryKey('collection')), findsNothing);
      expect(find.byKey(HomeScreen.entryKey('send_feedback')), findsOneWidget);
    });

    testWidgets('opens the list', (tester) async {
      await pumpHome(tester);
      await openTheList(tester);

      expect(find.byType(GameCollectionListScreen), findsOneWidget);
      expect(
        find.byKey(GameCollectionListScreen.rowKey('e-1')),
        findsOneWidget,
      );
    });

    testWidgets('a container with no hydrate still renders the list', (
      tester,
    ) async {
      // No status reads as settled, not as loading forever.
      await pumpHome(tester);
      await openTheList(tester);

      expect(find.byKey(GameCollectionListScreen.loadingKey), findsNothing);
      expect(find.text('Catan'), findsOneWidget);
    });
  });

  group('the retry', () {
    testWidgets('the banner reaches the session refresher', (tester) async {
      var calls = 0;
      await pumpHome(
        tester,
        failedPass: true,
        refresher: GameCollectionRefresher(() async => calls++),
      );
      await openTheList(tester);

      expect(
        find.byKey(GameCollectionListScreen.refreshBannerKey),
        findsOneWidget,
      );
      await tester.tap(find.byKey(GameCollectionListScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('a container with no refresher offers none', (tester) async {
      await pumpHome(tester, failedPass: true);
      await openTheList(tester);

      expect(
        find.byKey(GameCollectionListScreen.refreshBannerKey),
        findsOneWidget,
      );
      expect(
        find.byKey(GameCollectionListScreen.refreshRetryKey),
        findsNothing,
      );
    });
  });

  group('the entry trigger (#44)', () {
    testWidgets('opening the list asks the session for a stale pass', (
      tester,
    ) async {
      final rehydrator = _RecordingRehydrator();
      await pumpHome(tester, rehydrator: rehydrator);
      expect(rehydrator.passes, 0);

      await openTheList(tester);

      expect(rehydrator.passes, 1);
    });

    testWidgets('leaving and coming back fires again', (tester) async {
      final rehydrator = _RecordingRehydrator();
      await pumpHome(tester, rehydrator: rehydrator);
      await openTheList(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await openTheList(tester);

      expect(rehydrator.passes, 2);
    });

    testWidgets('the retry does not go through the rehydrator', (tester) async {
      // The rehydrator skips a pass that is already running, which is right
      // for a trigger and wrong for a button someone is waiting on.
      final rehydrator = _RecordingRehydrator();
      var calls = 0;
      await pumpHome(
        tester,
        failedPass: true,
        rehydrator: rehydrator,
        refresher: GameCollectionRefresher(() async => calls++),
      );
      await openTheList(tester);

      await tester.tap(find.byKey(GameCollectionListScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(rehydrator.passes, 1);
    });
  });
}
