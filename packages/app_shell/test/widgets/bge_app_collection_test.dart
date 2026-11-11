import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_collection/game_collection.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

/// Remembers the layout in memory, as the user-session store does on disk.
class _MemoryLayouts implements ListLayoutRepository {
  final stored = <ListLayoutScreen, ListLayout>{};

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async => stored[screen];

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async =>
      stored[screen] = layout;
}

/// A catalog with no games in it: enough for the browse screen to open.
class _EmptyCatalog implements GamesRemoteDataSource {
  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
    GameSort sort = GameSort.title,
  }) async => const PaginatedResult(
    items: [],
    meta: PaginationMeta(
      page: 1,
      limit: 50,
      total: 0,
      totalPages: 0,
      hasMore: false,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

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

/// The entry [id], of its own game unless [gameId] names one.
GameCollectionListItem _item(
  String id, {
  String? gameId,
  GameMedium medium = GameMedium.physical,
}) => GameCollectionListItem(
  entry: GameCollection(
    id: id,
    userId: 'u1',
    platformGameId: 'pg-$id',
    medium: medium,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  gameId: gameId ?? 'g-$id',
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
    List<GameCollectionListItem>? items,
    GamesRemoteDataSource? games,
    bool withSender = false,
    ListLayoutRepository? layouts,
  }) async {
    final repository = _MockGameCollectionRepository();
    when(repository.watchCollectionListItems).thenAnswer(
      (_) =>
          Stream<List<GameCollectionListItem>>.value(items ?? [_item('e-1')]),
    );
    when(() => repository.watchCollectionListItem(any())).thenAnswer(
      (invocation) => Stream<GameCollectionListItem?>.value(
        _item(invocation.positionalArguments.single as String),
      ),
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
          FakeAuthRepository(initialSession: testAuthResponse()),
          gameCollectionRepository: withRepository ? repository : null,
          syncOperationSender: withSender ? _MockSyncOperationSender() : null,
          gameCollectionHydrationStatus: status,
          gameCollectionRefresher: refresher,
          sessionRehydrator: rehydrator,
          gamesRemoteDataSource: games,
          listLayoutRepository: layouts,
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

  group('the empty list (#45)', () {
    testWidgets('browses to the catalog', (tester) async {
      await pumpHome(tester, items: const [], games: _EmptyCatalog());
      await openTheList(tester);

      await tester.tap(find.byKey(GameCollectionListScreen.browseKey));
      await tester.pumpAndSettle();

      expect(find.byType(GameBrowseScreen), findsOneWidget);

      // A push, so back returns to the collection.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(GameCollectionListScreen), findsOneWidget);
    });

    testWidgets('offers no browse where there is no catalog', (tester) async {
      await pumpHome(tester, items: const []);
      await openTheList(tester);

      expect(find.byKey(GameCollectionListScreen.emptyKey), findsOneWidget);
      expect(find.byKey(GameCollectionListScreen.browseKey), findsNothing);
    });
  });

  testWidgets('Collection thumbnails open the entry, and the choice survives '
      'leaving and coming back', (tester) async {
    final layouts = _MemoryLayouts();
    await pumpHome(tester, withSender: true, layouts: layouts);
    await openTheList(tester);
    expect(find.byKey(GameCollectionListScreen.rowKey('e-1')), findsOneWidget);

    await tester.tap(find.byTooltip('Thumbnails'));
    await tester.pumpAndSettle();
    expect(layouts.stored[ListLayoutScreen.collection], ListLayout.thumbnails);

    await tester.tap(find.byKey(GameCollectionListScreen.tileKey('e-1')));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionEntryScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(GameCollectionListScreen), findsNothing);
    await openTheList(tester);

    expect(find.byKey(GameCollectionListScreen.tileKey('e-1')), findsOneWidget);
    expect(find.byKey(GameCollectionListScreen.rowKey('e-1')), findsNothing);
  });

  group('the entry (#46)', () {
    testWidgets('tapping a row opens that entry', (tester) async {
      await pumpHome(tester, withSender: true);
      await openTheList(tester);

      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-1')));
      await tester.pumpAndSettle();

      expect(find.byType(CollectionEntryScreen), findsOneWidget);
    });

    testWidgets('back returns to the list', (tester) async {
      await pumpHome(tester, withSender: true);
      await openTheList(tester);
      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-1')));
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(GameCollectionListScreen), findsOneWidget);
      expect(find.byType(CollectionEntryScreen), findsNothing);
    });

    testWidgets('an id that needs encoding reaches the screen whole', (
      tester,
    ) async {
      await pumpHome(tester, withSender: true, items: [_item('e 1/x')]);
      await openTheList(tester);

      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e 1/x')));
      await tester.pumpAndSettle();

      final screen = tester.widget<CollectionEntryScreen>(
        find.byType(CollectionEntryScreen),
      );
      expect(screen.entryId, 'e 1/x');
    });

    testWidgets("the entry reads the session's collection hydrate", (
      tester,
    ) async {
      await pumpHome(tester, withSender: true, failedPass: true);
      await openTheList(tester);
      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-1')));
      await tester.pumpAndSettle();

      final screen = tester.widget<CollectionEntryScreen>(
        find.byType(CollectionEntryScreen),
      );
      expect(screen.hydration, isNotNull);
    });

    testWidgets('a container with no hydrate gives the entry none', (
      tester,
    ) async {
      await pumpHome(tester, withSender: true);
      await openTheList(tester);
      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-1')));
      await tester.pumpAndSettle();

      final screen = tester.widget<CollectionEntryScreen>(
        find.byType(CollectionEntryScreen),
      );
      expect(screen.hydration, isNull);
    });

    testWidgets('without a sender rows stay inert', (tester) async {
      await pumpHome(tester);
      await openTheList(tester);

      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-1')));
      await tester.pumpAndSettle();

      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(find.byType(GameCollectionListScreen), findsOneWidget);
    });

    testWidgets('a go from one entry to another drives the second', (
      tester,
    ) async {
      // go_router keys the route's page by its path pattern, so the go keeps
      // the page; the screen must not keep the first entry's bloc with it.
      await pumpHome(tester, withSender: true);
      await openTheList(tester);
      final router = GoRouter.of(
        tester.element(find.byType(GameCollectionListScreen)),
      )..go(AppRoutes.collectionEntryOf('e-1'));
      await tester.pumpAndSettle();
      router.go(AppRoutes.collectionEntryOf('e-2'));
      await tester.pumpAndSettle();

      final bloc = tester
          .element(find.byType(CollectionEntryDetail))
          .read<CollectionEntryBloc>();
      expect(bloc.entryId, 'e-2');
    });

    testWidgets('without a sender the entry route is not available', (
      tester,
    ) async {
      await pumpHome(tester);
      await openTheList(tester);

      GoRouter.of(tester.element(find.byType(GameCollectionListScreen)))
          .go(AppRoutes.collectionEntryOf('e-1'));
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(CollectionEntryScreen), findsNothing);
    });

    testWidgets('game details opens the game when there is a catalog', (
      tester,
    ) async {
      await pumpHome(tester, withSender: true, games: _EmptyCatalog());
      await openTheList(tester);
      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-1')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(CollectionEntryScreen.gameDetailsKey),
      );
      await tester.tap(find.byKey(CollectionEntryScreen.gameDetailsKey));
      await tester.pumpAndSettle();

      expect(find.byType(GameDetailScreen), findsOneWidget);
    });

    testWidgets('offers no game details where there is no catalog', (
      tester,
    ) async {
      await pumpHome(tester, withSender: true);
      await openTheList(tester);
      await tester.tap(find.byKey(GameCollectionListScreen.rowKey('e-1')));
      await tester.pumpAndSettle();

      expect(find.byType(CollectionEntryScreen), findsOneWidget);
      expect(
        find.byKey(CollectionEntryScreen.gameDetailsKey, skipOffstage: false),
        findsNothing,
      );
    });
  });

  group('the picker (#709)', () {
    // A stack's picker lists the departing user's copies. It is a pop-up on
    // the root navigator, with no page of its own, so it goes with
    // Collection's page as the session's end routes away from it.
    testWidgets('the picker closes as the session ends', (tester) async {
      final repository = _MockGameCollectionRepository();
      when(repository.watchCollectionListItems).thenAnswer(
        (_) => Stream.value([
          _item('e-1'),
          _item('e-2', gameId: 'g-e-1', medium: GameMedium.digital),
        ]),
      );
      final repo = FakeAuthRepository(initialSession: testAuthResponse());
      final app = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(
          activeServerScope: FakeActiveServerScope(
            buildActiveServer(
              repo,
              gameCollectionRepository: repository,
              // Without one a stack is inert.
              syncOperationSender: _MockSyncOperationSender(),
            ),
          ),
        ),
        hydratedStorageInitializer: (_) async {},
      );
      addTearDown(app.close);
      await tester.pumpWidget(BgeApp(bootstrapCubit: app));
      await app.initialize();
      await tester.pumpAndSettle();
      await openTheList(tester);

      await tester.tap(find.byKey(GameCollectionListScreen.stackKey('g-e-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(CollectionEntryPicker.tileKey('e-1')), findsOneWidget);
      expect(find.byKey(CollectionEntryPicker.tileKey('e-2')), findsOneWidget);

      repo.emitAuthState(const AuthStateUnauthenticated());
      await tester.pumpAndSettle();

      expect(find.byType(GameCollectionListScreen), findsNothing);
      for (final id in ['e-1', 'e-2']) {
        expect(
          find.byKey(CollectionEntryPicker.tileKey(id), skipOffstage: false),
          findsNothing,
        );
      }
    });
  });
}
