import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_collection/game_collection.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
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

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

/// A sender whose every send is delivered.
_MockSyncOperationSender _deliveringSender() {
  final sender = _MockSyncOperationSender();
  when(() => sender.deliver(any(), any()))
      .thenAnswer((_) async => const SyncDelivered());
  return sender;
}

/// Remembers the layout in memory, as the user-session store does on disk.
class _MemoryLayouts implements ListLayoutRepository {
  final stored = <ListLayoutScreen, ListLayout>{};

  @override
  Future<ListLayout?> read(ListLayoutScreen screen) async => stored[screen];

  @override
  Future<void> write(ListLayoutScreen screen, ListLayout layout) async =>
      stored[screen] = layout;
}

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

final _catan = Game(
  id: 'g_catan',
  title: 'Catan',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// Catan's platform.
final _tabletop = PlatformGame(
  id: 'pg_1',
  gameId: 'g_catan',
  platformId: 'plat_tabletop',
  platformName: 'Tabletop',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// A second platform, for a Catan on two.
final _steam = PlatformGame(
  id: 'pg_2',
  gameId: 'g_catan',
  platformId: 'plat_steam',
  platformName: 'Steam',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// The user's copy [id] of Catan on Tabletop, in [medium].
GameCollection _copy(String id, GameMedium medium) => GameCollection(
  id: id,
  userId: 'u1',
  platformGameId: 'pg_1',
  medium: medium,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// A collection repository whose adds succeed. What the user owns of a game
/// is what [owned] reports, and nothing without it: an add lands on
/// [owned], as a write to the cache reaches its watches.
_MockGameCollectionRepository _collection({
  StreamController<List<GameCollection>>? owned,
}) {
  final repository = _MockGameCollectionRepository();
  when(repository.watchCollectionListItems)
      .thenAnswer((_) => Stream.value(const []));
  when(() => repository.watchEntriesForPlatformGames(any()))
      .thenAnswer((_) => owned?.stream ?? Stream.value(const []));
  when(() => repository.watchCollectionListItem(any())).thenAnswer(
    (invocation) => Stream.value(
      GameCollectionListItem(
        entry: _copy(
          invocation.positionalArguments.single as String,
          GameMedium.physical,
        ),
        gameId: 'g_catan',
        title: 'Catan',
        platformName: 'Tabletop',
      ),
    ),
  );
  when(
    () => repository.getCollectionEntry(
      platformGameId: any(named: 'platformGameId'),
      medium: any(named: 'medium'),
    ),
  ).thenAnswer((_) async => null);
  when(
    () => repository.addToCollection(
      platformGameId: any(named: 'platformGameId'),
      medium: any(named: 'medium'),
      quantity: any(named: 'quantity'),
      rating: any(named: 'rating'),
      comment: any(named: 'comment'),
    ),
  ).thenAnswer((invocation) async {
    final medium = invocation.namedArguments[#medium] as GameMedium;
    final entry = _copy('gc_1', medium);
    owned?.add([entry]);
    return (
      entry: entry,
      syncQueueId: 'sq_1',
      operation: AddToCollectionOperation(
        localId: 'gc_1',
        platformGameId: 'pg_1',
        medium: medium.toWire(),
        quantity: 1,
      ),
    );
  });
  return repository;
}

/// One game in the catalog, found by every search with one DataGateway
/// result, which imports as `g_seafarers`.
class _GamesRemote implements GamesRemoteDataSource {
  /// Games whose detail answers 404, as one deleted since the list loaded.
  final Set<String> gone = {};

  /// When set, every detail waits for it, as on a slow server.
  Completer<GameWithPlatformGames>? held;

  /// The ids every detail read asked for.
  final List<String> fetched = [];

  /// The order each list read asked for.
  final List<GameSort> sorts = [];

  /// Where every poll says the import's base game stands.
  ImportJobStatus importStatus = ImportJobStatus.completed;

  /// The platforms every detail read gives Catan.
  List<PlatformGame> platformGames = [_tabletop];

  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
    GameSort sort = GameSort.title,
  }) async {
    sorts.add(sort);
    return PaginatedResult(
      items: [_catan],
      meta: const PaginationMeta(
        page: 1,
        limit: 50,
        total: 1,
        totalPages: 1,
        hasMore: false,
      ),
    );
  }

  @override
  Future<List<GameSummary>> fetchRandom({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) async => const [];

  @override
  Future<GameWithPlatformGames> fetchGame(String id) async {
    fetched.add(id);
    final held = this.held;
    if (held != null) return held.future;
    if (gone.contains(id)) throw const GameNotFoundException('404');
    return (game: _catan, platformGames: platformGames);
  }

  @override
  Future<GameSearchResults> search(
    String query, {
    int limit = GamesRemoteDataSource.searchPageSize,
    int offset = 0,
    GameSearchFilter filter = const GameSearchFilter(),
  }) async => const GameSearchResults(
    local: [
      GameSearchHit(
        externalId: 'g_catan',
        gameId: 'g_catan',
        title: 'Catan',
        contentType: ContentType.baseGame,
      ),
    ],
    byDataGateway: {
      'dg_bgg': [
        GameSearchHit(
          externalId: '926',
          title: 'Catan: Seafarers',
          contentType: ContentType.expansion,
        ),
      ],
    },
  );

  @override
  Future<GameImportReceipt> startImport({
    required String gatewayId,
    required String externalId,
    required String correlationId,
  }) async => GameImportReceipt(
    batchId: '0b7c2f9e-3a41-4c8e-9d2a-5f6b7c8d9e0f',
    baseJobId: 'job_base',
    correlationId: correlationId,
  );

  @override
  Future<ImportBatch> fetchImport(String batchId) async => ImportBatch(
    batchId: batchId,
    correlationId: '5a1e4b3c-2d6f-4a8b-9c0d-1e2f3a4b5c6d',
    status: ImportBatchStatus.running,
    jobs: [
      ImportJob(
        jobId: 'job_base',
        status: importStatus,
        isExpansion: false,
        externalId: '926',
        gameId: importStatus == ImportJobStatus.completed
            ? 'g_seafarers'
            : null,
      ),
    ],
  );
}

/// Lists one DataGateway, named.
class _DataGatewayRemote implements DataGatewayRemoteDataSource {
  /// How many pages of the list were asked for.
  int reads = 0;

  /// Thrown by every list read, when set.
  Exception? error;

  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) async {
    reads++;
    if (error case final error?) throw error;
    return _oneDataGateway;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _oneDataGateway = PaginatedResult<DataGateway>(
  items: [
    DataGateway(
      id: 'dg_bgg',
      name: 'BoardGameGeek',
      connectionUrl: 'bgg.internal',
      connectionPort: 50051,
      enabled: true,
      authType: DataGatewayAuthType.none,
    ),
  ],
  meta: PaginationMeta(
    page: 1,
    limit: 100,
    total: 1,
    totalPages: 1,
    hasMore: false,
  ),
);

/// The answer of a caller who may read DataGateways.
final CallerAccess _mayRead = FakeCallerAccessRepository.dataGateway(
  read: AccessExtent.all,
);

/// The Games entry in the home drawer and the screens behind it (#42).
void main() {
  late _MockAppBootstrapCubit cubit;
  late _DataGatewayRemote dataGateways;
  late FakeCallerAccessRepository access;
  late _GamesRemote games;

  setUpAll(() {
    registerFallbackValue(GameMedium.physical);
    registerFallbackValue(<String>{});
    registerFallbackValue(
      const AddToCollectionOperation(
        localId: 'gc_fallback',
        platformGameId: 'pg_fallback',
        medium: 'Physical',
        quantity: 1,
      ),
    );
  });

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    dataGateways = _DataGatewayRemote();
    games = _GamesRemote();
    access = FakeCallerAccessRepository();
  });

  /// The active server [pumpHome] builds, with [collection] as its user
  /// session's collection repository.
  FakeActiveServerScope activeServer({
    bool withGames = true,
    ListLayoutRepository? layouts,
    GameCollectionRepository? collection,
    GameCollectionHydrationStatus? collectionHydration,
    SyncOperationSender? sender,
  }) => FakeActiveServerScope(
    buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
      gamesRemoteDataSource: withGames ? games : null,
      listLayoutRepository: layouts,
      dataGatewayRemoteDataSource: dataGateways,
      callerAccess: access,
      gameCollectionRepository: collection,
      gameCollectionHydrationStatus: collectionHydration,
      syncOperationSender: sender,
    ),
  );

  Future<void> pumpHome(
    WidgetTester tester, {
    bool withGames = true,
    ListLayoutRepository? layouts,
    GameCollectionRepository? collection,
    GameCollectionHydrationStatus? collectionHydration,
    SyncOperationSender? sender,
  }) async {
    when(() => cubit.activeServerScope).thenReturn(
      activeServer(
        withGames: withGames,
        layouts: layouts,
        collection: collection,
        collectionHydration: collectionHydration,
        sender: sender,
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

  Future<void> openGames(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HomeScreen.entryKey('games')));
    await tester.pumpAndSettle();
  }

  Future<void> searchFor(WidgetTester tester, String text) async {
    await tester.tap(find.byKey(GameBrowseScreen.searchKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(GameSearchScreen.fieldKey), text);
    await tester.pump(GameSearchBloc.defaultDebounce);
    await tester.pumpAndSettle();
  }

  testWidgets('the entry opens the catalog, and a row opens its game', (
    tester,
  ) async {
    await pumpHome(tester);
    // Home's "Recently added" row has read already.
    games.sorts.clear();
    await openGames(tester);

    expect(find.byType(GameBrowseScreen), findsOneWidget);
    // The drawer's entry lists by title, whatever was chosen the last time.
    expect(games.sorts, [GameSort.title]);

    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_catan')));
    await tester.pumpAndSettle();

    expect(find.byType(GameDetailScreen), findsOneWidget);
  });

  testWidgets('Games thumbnails open the quick look, and the choice survives '
      'leaving and coming back', (tester) async {
    final layouts = _MemoryLayouts();
    await pumpHome(tester, layouts: layouts);
    await openGames(tester);
    expect(find.byKey(GameBrowseScreen.rowKey('g_catan')), findsOneWidget);

    await tester.tap(find.byTooltip('Thumbnails'));
    await tester.pumpAndSettle();
    expect(layouts.stored[ListLayoutScreen.games], ListLayout.thumbnails);

    // A pop-up over the list, not a page.
    await tester.tap(find.byKey(GameBrowseScreen.tileKey('g_catan')));
    await tester.pumpAndSettle();
    expect(find.byType(GameQuickLook), findsOneWidget);
    expect(find.byType(GameDetailScreen), findsNothing);
    expect(find.byType(GameBrowseScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(GameQuickLook), findsNothing);

    (tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
            as GoRouter)
        .go(AppRoutes.home);
    await tester.pumpAndSettle();
    expect(find.byType(GameBrowseScreen), findsNothing);
    await openGames(tester);

    expect(find.byKey(GameBrowseScreen.tileKey('g_catan')), findsOneWidget);
    expect(find.byKey(GameBrowseScreen.rowKey('g_catan')), findsNothing);
  });

  testWidgets('a thumbnail whose game is found gone leaves the grid, and '
      'View full details still opens', (tester) async {
    games.gone.add('g_catan');
    await pumpHome(
      tester,
      layouts: _MemoryLayouts()
        ..stored[ListLayoutScreen.games] = ListLayout.thumbnails,
    );
    await openGames(tester);
    final tile = find.byKey(GameBrowseScreen.tileKey('g_catan'));
    expect(tile, findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(GameQuickLook.unavailableKey), findsOneWidget);
    // The tile the pop-up opened from has unmounted.
    expect(tile, findsNothing);

    await tester.tap(find.byKey(GameQuickLook.viewDetailsKey));
    await tester.pumpAndSettle();

    expect(find.byType(GameDetailScreen), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(GameBrowseScreen), findsOneWidget);
    expect(find.byType(GameQuickLook, skipOffstage: false), findsNothing);
  });

  testWidgets('View full details from a Games thumbnail opens the game over '
      'the quick look, and back lands on Games without it, on the tile', (
    tester,
  ) async {
    await pumpHome(
      tester,
      layouts: _MemoryLayouts()
        ..stored[ListLayoutScreen.games] = ListLayout.thumbnails,
    );
    await openGames(tester);
    final tile = find.byKey(GameBrowseScreen.tileKey('g_catan'));
    final tileFocus = tester
        .widget<InkWell>(
          find.descendant(of: tile, matching: find.byType(InkWell)),
        )
        .focusNode!;

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(GameQuickLook), findsOneWidget);

    await tester.tap(find.byKey(GameQuickLook.viewDetailsKey));
    await tester.pumpAndSettle();
    expect(find.byType(GameDetailScreen), findsOneWidget);
    // Gone once the page has arrived, not just hidden under it.
    expect(find.byType(GameQuickLook, skipOffstage: false), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(GameDetailScreen), findsNothing);
    expect(find.byType(GameBrowseScreen), findsOneWidget);
    expect(find.byType(GameQuickLook, skipOffstage: false), findsNothing);
    expect(tile, findsOneWidget);
    // The tap gave the tile focus, so that it comes back there.
    expect(FocusManager.instance.primaryFocus, same(tileFocus));
  });

  testWidgets('a location that names a sort opens the catalog in it', (
    tester,
  ) async {
    await pumpHome(tester);
    // Home's "Recently added" row has read already.
    games.sorts.clear();

    final router =
        tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
            as GoRouter;
    unawaited(router.push(AppRoutes.gamesSorted(GameSort.newest)));
    await tester.pumpAndSettle();

    expect(find.byType(GameBrowseScreen), findsOneWidget);
    expect(games.sorts, [GameSort.newest]);
  });

  testWidgets('going to another sort of the catalog reads it in that sort', (
    tester,
  ) async {
    await pumpHome(tester);
    final router =
        tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter
          ..go(AppRoutes.games);
    await tester.pumpAndSettle();
    games.sorts.clear();

    // As an edited address bar does: the path is the same, so go_router keeps
    // the page and builds the screen again in place.
    router.go(AppRoutes.gamesSorted(GameSort.newest));
    await tester.pumpAndSettle();
    expect(games.sorts, [GameSort.newest]);

    router.go(AppRoutes.games);
    await tester.pumpAndSettle();
    expect(games.sorts, [GameSort.newest, GameSort.title]);
  });

  testWidgets('a game found gone is gone from the list the user returns to', (
    tester,
  ) async {
    games.gone.add('g_catan');
    await pumpHome(tester);
    await openGames(tester);

    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_catan')));
    await tester.pumpAndSettle();
    expect(find.byKey(GameDetailScreen.unavailableKey), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(GameBrowseScreen), findsOneWidget);
    expect(find.byKey(GameBrowseScreen.rowKey('g_catan')), findsNothing);
  });

  testWidgets('a game found gone from a search is gone from the list beneath '
      'it, too', (tester) async {
    games.gone.add('g_catan');
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    await tester.tap(find.byKey(GameSearchScreen.serverRowKey('g_catan')));
    await tester.pumpAndSettle();
    expect(find.byKey(GameDetailScreen.unavailableKey), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(GameSearchScreen.serverRowKey('g_catan')), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(GameBrowseScreen), findsOneWidget);
    expect(find.byKey(GameBrowseScreen.rowKey('g_catan')), findsNothing);
  });

  testWidgets('a game found gone after a sign-out is not taken off the next '
      "user's list", (tester) async {
    final repo = FakeAuthRepository(initialSession: testAuthResponse());
    final app = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        activeServerScope: FakeActiveServerScope(
          buildActiveServer(
            repo,
            gamesRemoteDataSource: games,
            dataGatewayRemoteDataSource: dataGateways,
            callerAccess: access,
          ),
        ),
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(app.close);
    await tester.pumpWidget(BgeApp(bootstrapCubit: app));
    await app.initialize();
    await tester.pumpAndSettle();
    await openGames(tester);

    // Catan is opened on a slow server, and the session ends before it
    // answers.
    final held = games.held = Completer();
    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_catan')));
    // The spinner never settles, so pump past the push transition instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byKey(GameDetailScreen.loadingKey), findsOneWidget);
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pumpAndSettle();
    expect(find.byType(GameDetailScreen), findsNothing);

    // The next user opens the catalog, and then the old read answers.
    final first = testAuthResponse();
    repo.emitAuthState(
      AuthStateAuthenticated(
        session: first.copyWith(
          token: 'tok-u2',
          user: first.user.copyWith(id: 'u2', email: 'u2@example.com'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    games.held = null;
    await openGames(tester);
    held.completeError(const GamesForbiddenException('403'));
    await tester.pumpAndSettle();

    // Refused to the user who asked, not to this one.
    expect(find.byKey(GameBrowseScreen.rowKey('g_catan')), findsOneWidget);
  });

  testWidgets('no games remote is no entry', (tester) async {
    await pumpHome(tester, withGames: false);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.byKey(HomeScreen.entryKey('games')), findsNothing);
  });

  testWidgets('search names a DataGateway for a user who may read them', (
    tester,
  ) async {
    access.current = _mayRead;
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    expect(find.textContaining('BoardGameGeek'), findsOneWidget);
  });

  testWidgets('search names are read only with read (#456)', (tester) async {
    // Every other DataGateway action, and not read.
    access.current = FakeCallerAccessRepository.dataGateway(
      create: AccessExtent.all,
      update: AccessExtent.all,
      delete: AccessExtent.all,
    );
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    expect(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
      findsOneWidget,
    );
    expect(find.textContaining('BoardGameGeek'), findsNothing);
    expect(dataGateways.reads, 0);
  });

  testWidgets('a refused name read asks access again (#456)', (tester) async {
    access.current = _mayRead;
    dataGateways.error = const DataGatewayForbiddenException(
      'refused',
      statusCode: 403,
    );
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    expect(dataGateways.reads, 1);
    expect(access.refreshCount, 1);
    // The results stand, unnamed.
    expect(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
      findsOneWidget,
    );
    expect(find.textContaining('BoardGameGeek'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a DataGateway result imports and opens the game', (
    tester,
  ) async {
    access.current = _mayRead;
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    await tester.tap(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(GameImportDialog), findsNothing);
    expect(find.byType(GameDetailScreen), findsOneWidget);
    expect(games.fetched, contains('g_seafarers'));
  });

  testWidgets('closing the import opens nothing', (tester) async {
    games.importStatus = ImportJobStatus.running;
    access.current = _mayRead;
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    await tester.tap(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(GameImportDialog.closeKey));
    await tester.pump(const Duration(seconds: 4));

    expect(find.byType(GameDetailScreen), findsNothing);
    expect(find.byType(GameSearchScreen), findsOneWidget);
  });

  group("the detail page's collection (#45, #708)", () {
    final addButton = find.byKey(GameDetailScreen.addKey);
    final ownedLegend = find.byKey(GameDetailScreen.ownedLegendKey);
    const tabletopOwned = 'Tabletop, in your collection, opens your copy';
    const tabletopNotOwned = 'Tabletop, not in your collection, add';

    /// The picker's tile for [entryId], built or not.
    Finder tile(String entryId) =>
        find.byKey(CollectionEntryPicker.tileKey(entryId), skipOffstage: false);

    Future<void> openCatan(WidgetTester tester) async {
      await openGames(tester);
      await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_catan')));
      await tester.pumpAndSettle();
    }

    /// Presses the detail page's chip for [platformGameId].
    Future<void> tapChip(WidgetTester tester, String platformGameId) async {
      final chip = find.byKey(GameDetailScreen.platformKey(platformGameId));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }

    /// Picks Physical in the open add sheet and submits it.
    Future<void> addPhysical(WidgetTester tester) async {
      await tester.tap(find.byKey(AddToCollectionSheet.mediumKey));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(MenuItemButton),
          matching: find.text('Physical'),
        ),
      );
      await tester.pumpAndSettle();
      final submit = find.byKey(AddToCollectionSheet.submitKey);
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pumpAndSettle();
    }

    /// The entry page open now.
    CollectionEntryScreen entryPage(WidgetTester tester) => tester
        .widget<CollectionEntryScreen>(find.byType(CollectionEntryScreen));

    testWidgets('Add opens the add sheet, which adds through the session', (
      tester,
    ) async {
      final collection = _collection();
      final sender = _deliveringSender();
      await pumpHome(tester, collection: collection, sender: sender);
      await openCatan(tester);

      await tester.tap(addButton);
      await tester.pumpAndSettle();
      expect(find.text('Add Catan'), findsOneWidget);
      await addPhysical(tester);

      verify(
        () => collection.addToCollection(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
        ),
      ).called(1);
      // Sent at once, through the session's sender (#45).
      verify(() => sender.deliver('sq_1', any())).called(1);
      expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
      expect(find.byType(GameDetailScreen), findsOneWidget);
      expect(find.text('Added Catan to your collection.'), findsOneWidget);
    });

    testWidgets('detail → Add → the add lands and the chip turns owned', (
      tester,
    ) async {
      final owned = StreamController<List<GameCollection>>()..add(const []);
      addTearDown(owned.close);
      await pumpHome(
        tester,
        collection: _collection(owned: owned),
        sender: _deliveringSender(),
      );
      await openCatan(tester);
      expect(find.bySemanticsLabel(tabletopNotOwned), findsOneWidget);
      expect(ownedLegend, findsNothing);

      await tester.tap(addButton);
      await tester.pumpAndSettle();
      await addPhysical(tester);

      expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
      expect(find.bySemanticsLabel(tabletopOwned), findsOneWidget);
      expect(find.bySemanticsLabel(tabletopNotOwned), findsNothing);
      expect(ownedLegend, findsOneWidget);
      // Digital is still free on Tabletop.
      expect(addButton, findsOneWidget);
    });

    testWidgets("until the collection's first refresh lands, the detail says "
        'nothing of ownership; then the chip turns owned', (tester) async {
      final owned = StreamController<List<GameCollection>>()..add(const []);
      addTearDown(owned.close);
      final status = GameCollectionHydrationStatus()..started();
      addTearDown(status.close);
      await pumpHome(
        tester,
        collection: _collection(owned: owned),
        collectionHydration: status,
        sender: _deliveringSender(),
      );
      await openCatan(tester);

      // The empty cache is unknown, not "not owned".
      expect(find.byKey(GameDetailScreen.platformKey('pg_1')), findsOneWidget);
      expect(find.bySemanticsLabel(tabletopNotOwned), findsNothing);
      expect(addButton, findsNothing);

      owned.add([_copy('gc_1', GameMedium.physical)]);
      status.finished(CollectionHydrateOutcome.complete);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(tabletopOwned), findsOneWidget);
      expect(ownedLegend, findsOneWidget);
    });

    testWidgets('after a failed first refresh, ownership is unknown: plain '
        'chips, and the add still opens', (tester) async {
      final owned = StreamController<List<GameCollection>>()..add(const []);
      addTearDown(owned.close);
      final status = GameCollectionHydrationStatus()
        ..started()
        ..finished(CollectionHydrateOutcome.failed);
      addTearDown(status.close);
      await pumpHome(
        tester,
        collection: _collection(owned: owned),
        collectionHydration: status,
        sender: _deliveringSender(),
      );
      await openCatan(tester);

      expect(find.bySemanticsLabel(tabletopNotOwned), findsNothing);
      expect(find.bySemanticsLabel(tabletopOwned), findsNothing);
      expect(ownedLegend, findsNothing);
      await tester.ensureVisible(addButton);
      await tester.pumpAndSettle();
      await tester.tap(addButton);
      await tester.pumpAndSettle();
      expect(find.text('Add Catan'), findsOneWidget);
    });

    testWidgets('an unowned chip opens the add on its platform', (
      tester,
    ) async {
      games.platformGames = [_tabletop, _steam];
      await pumpHome(
        tester,
        collection: _collection(),
        sender: _deliveringSender(),
      );
      await openCatan(tester);

      await tapChip(tester, 'pg_2');

      expect(find.byKey(AddToCollectionSheet.sheetKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(AddToCollectionSheet.platformKey),
          matching: find.text('Steam'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('detail → owned chip with one entry opens the entry page', (
      tester,
    ) async {
      final owned = StreamController<List<GameCollection>>()
        ..add([_copy('gc_1', GameMedium.physical)]);
      addTearDown(owned.close);
      await pumpHome(
        tester,
        collection: _collection(owned: owned),
        sender: _deliveringSender(),
      );
      await openCatan(tester);
      expect(find.bySemanticsLabel(tabletopOwned), findsOneWidget);

      await tapChip(tester, 'pg_1');

      expect(entryPage(tester).entryId, 'gc_1');
      expect(tile('gc_1'), findsNothing);

      // A push, so back returns to the game.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(find.byType(GameDetailScreen), findsOneWidget);
    });

    testWidgets('detail → owned chip with two entries opens the picker; a tile '
        'opens that entry, and back lands on the detail page with no picker', (
      tester,
    ) async {
      final owned = StreamController<List<GameCollection>>()
        ..add([
          _copy('gc_1', GameMedium.physical),
          _copy('gc_2', GameMedium.digital),
        ]);
      addTearDown(owned.close);
      await pumpHome(
        tester,
        collection: _collection(owned: owned),
        sender: _deliveringSender(),
      );
      await openCatan(tester);

      await tapChip(tester, 'pg_1');
      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(tile('gc_1'), findsOneWidget);
      expect(tile('gc_2'), findsOneWidget);

      await tester.tap(find.byKey(CollectionEntryPicker.tileKey('gc_2')));
      await tester.pumpAndSettle();
      expect(entryPage(tester).entryId, 'gc_2');
      // Gone once the page has arrived, not just hidden under it.
      expect(tile('gc_1'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(find.byType(GameDetailScreen), findsOneWidget);
      expect(tile('gc_1'), findsNothing);
      expect(tile('gc_2'), findsNothing);
    });

    // Opened from an owned chip, the picker goes with the detail's page, as
    // Collection's does with its own.
    testWidgets('the picker over the detail page closes as the session ends', (
      tester,
    ) async {
      final repo = FakeAuthRepository(initialSession: testAuthResponse());
      final owned = StreamController<List<GameCollection>>()
        ..add([
          _copy('gc_1', GameMedium.physical),
          _copy('gc_2', GameMedium.digital),
        ]);
      addTearDown(owned.close);
      final app = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(
          activeServerScope: FakeActiveServerScope(
            buildActiveServer(
              repo,
              gamesRemoteDataSource: games,
              dataGatewayRemoteDataSource: dataGateways,
              callerAccess: access,
              gameCollectionRepository: _collection(owned: owned),
              syncOperationSender: _deliveringSender(),
            ),
          ),
        ),
        hydratedStorageInitializer: (_) async {},
      );
      addTearDown(app.close);
      await tester.pumpWidget(BgeApp(bootstrapCubit: app));
      await app.initialize();
      await tester.pumpAndSettle();
      await openCatan(tester);
      await tapChip(tester, 'pg_1');
      expect(tile('gc_1'), findsOneWidget);

      repo.emitAuthState(const AuthStateUnauthenticated());
      await tester.pumpAndSettle();

      expect(find.byType(GameDetailScreen), findsNothing);
      expect(tile('gc_1'), findsNothing);
      expect(tile('gc_2'), findsNothing);
    });

    testWidgets('no collection repository offers no add', (tester) async {
      await pumpHome(tester, sender: _deliveringSender());
      await openCatan(tester);

      expect(find.byKey(GameDetailScreen.platformKey('pg_1')), findsOneWidget);
      expect(find.bySemanticsLabel(tabletopNotOwned), findsNothing);
      expect(addButton, findsNothing);
    });

    testWidgets('no sender to send the add through offers no add, and watches '
        'nothing', (tester) async {
      final collection = _collection();
      await pumpHome(tester, collection: collection);
      await openCatan(tester);

      expect(find.byKey(GameDetailScreen.platformKey('pg_1')), findsOneWidget);
      expect(find.bySemanticsLabel(tabletopNotOwned), findsNothing);
      expect(addButton, findsNothing);
      verifyNever(() => collection.watchEntriesForPlatformGames(any()));
    });

    testWidgets('the watch reads the repository active when the page asks, '
        'not the one the detail was built with', (tester) async {
      final built = _collection();
      final owned = StreamController<List<GameCollection>>()
        ..add([_copy('gc_1', GameMedium.physical)]);
      addTearDown(owned.close);
      final current = _collection(owned: owned);
      final currentSender = _deliveringSender();
      await pumpHome(tester, collection: built, sender: _deliveringSender());
      // The detail's route is built, and its game is still loading.
      final held = games.held = Completer();
      await openGames(tester);
      await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_catan')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byKey(GameDetailScreen.loadingKey), findsOneWidget);

      when(() => cubit.activeServerScope)
          .thenReturn(activeServer(collection: current, sender: currentSender));
      held.complete((game: _catan, platformGames: [_tabletop]));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(tabletopOwned), findsOneWidget);
      verify(() => current.watchEntriesForPlatformGames({'pg_1'})).called(1);
      verifyNever(() => built.watchEntriesForPlatformGames(any()));
    });

    testWidgets('with no repository active when the page asks, nothing reads '
        'as owned', (tester) async {
      // Not closed after the test: its close waits for a listener, and the
      // test is that there is none.
      final owned = StreamController<List<GameCollection>>()
        ..add([_copy('gc_1', GameMedium.physical)]);
      final built = _collection(owned: owned);
      await pumpHome(tester, collection: built, sender: _deliveringSender());
      final held = games.held = Completer();
      await openGames(tester);
      await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_catan')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));

      when(() => cubit.activeServerScope).thenReturn(activeServer());
      held.complete((game: _catan, platformGames: [_tabletop]));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(tabletopOwned), findsNothing);
      expect(find.bySemanticsLabel(tabletopNotOwned), findsOneWidget);
      verifyNever(() => built.watchEntriesForPlatformGames(any()));
    });

    testWidgets('the add goes through the repository active at the press, '
        'not the one the detail was built with', (tester) async {
      final built = _collection();
      final builtSender = _deliveringSender();
      final current = _collection();
      final currentSender = _deliveringSender();
      await pumpHome(tester, collection: built, sender: builtSender);
      await openCatan(tester);

      // A session change the detail's route has not been rebuilt for: the
      // repository and sender it was built with are disposed by then.
      when(() => cubit.activeServerScope)
          .thenReturn(activeServer(collection: current, sender: currentSender));
      await tester.tap(addButton);
      await tester.pumpAndSettle();
      await addPhysical(tester);

      verify(
        () => current.addToCollection(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
        ),
      ).called(1);
      verifyNever(
        () => built.addToCollection(
          platformGameId: any(named: 'platformGameId'),
          medium: any(named: 'medium'),
          quantity: any(named: 'quantity'),
          rating: any(named: 'rating'),
          comment: any(named: 'comment'),
        ),
      );
      verify(() => currentSender.deliver('sq_1', any())).called(1);
      verifyNever(() => builtSender.deliver(any(), any()));
    });

    testWidgets('a press once the session has no collection repository opens '
        'nothing', (tester) async {
      await pumpHome(
        tester,
        collection: _collection(),
        sender: _deliveringSender(),
      );
      await openCatan(tester);

      when(() => cubit.activeServerScope).thenReturn(activeServer());
      await tester.tap(addButton);
      await tester.pumpAndSettle();

      expect(find.byKey(AddToCollectionSheet.sheetKey), findsNothing);
      expect(find.byType(GameDetailScreen), findsOneWidget);
    });

    testWidgets('an owned chip pressed once the session has no collection '
        'repository opens nothing', (tester) async {
      final owned = StreamController<List<GameCollection>>()
        ..add([_copy('gc_1', GameMedium.physical)]);
      addTearDown(owned.close);
      await pumpHome(
        tester,
        collection: _collection(owned: owned),
        sender: _deliveringSender(),
      );
      await openCatan(tester);
      expect(find.bySemanticsLabel(tabletopOwned), findsOneWidget);

      when(() => cubit.activeServerScope).thenReturn(activeServer());
      await tapChip(tester, 'pg_1');

      expect(find.byType(CollectionEntryScreen), findsNothing);
      expect(find.byType(GameDetailScreen), findsOneWidget);
    });
  });
}
