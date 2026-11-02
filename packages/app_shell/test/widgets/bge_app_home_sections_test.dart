import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:events/events.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:game_collection/game_collection.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

Game _game(String id) => Game(
  id: id,
  title: 'Game $id',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// A server holding [games], which lists them and draws them at random in the
/// order given.
class _GamesRemote implements GamesRemoteDataSource {
  _GamesRemote(this.games);

  /// What the server answers with, for whoever is asking.
  List<Game> games;

  /// Games whose detail answers 404, as one deleted since the list loaded.
  final Set<String> gone = {};

  /// The order each list read asked for.
  final List<GameSort> sorts = [];

  int randomReads = 0;

  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
    GameSort sort = GameSort.title,
  }) async {
    sorts.add(sort);
    return PaginatedResult(
      items: games,
      meta: PaginationMeta(
        page: 1,
        limit: limit,
        total: games.length,
        totalPages: 1,
        hasMore: false,
      ),
    );
  }

  @override
  Future<List<GameSummary>> fetchRandom({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) async {
    randomReads++;
    return [
      for (final game in games) GameSummary(id: game.id, title: game.title),
    ];
  }

  @override
  Future<GameWithPlatformGames> fetchGame(String id) async {
    if (gone.contains(id)) throw const GameNotFoundException('404');
    return (game: _game(id), platformGames: const <PlatformGameSummary>[]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The households' shared pool: [gameCount] games, none of them sampled, so
/// that a shelf falls through to the server's random ones.
class _Pool implements HouseholdRemoteDataSource {
  _Pool({this.gameCount = 0});

  int gameCount;
  int reads = 0;

  @override
  Future<GamePoolSample> fetchGamePoolSample({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) async {
    reads++;
    return (games: const <GameSummary>[], gameCount: gameCount);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A collection cache holding one entry per id in [gameIds]. Its stream stays
/// open, as Drift's does, or fails when [fails] says so.
class _Collection implements GameCollectionRepository {
  _Collection([this.gameIds = const [], this.fails = false]);

  final List<String> gameIds;
  final bool fails;
  int watches = 0;

  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() {
    watches++;
    return Stream.multi((stream) {
      if (fails) {
        stream.addError(StateError('the collection failed'));
        return;
      }
      stream.add([
        for (final id in gameIds)
          GameCollectionListItem(
            entry: GameCollection(
              id: 'entry-$id',
              userId: 'u1',
              platformGameId: 'pg-$id',
              medium: GameMedium.physical,
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
            gameId: id,
            title: 'Game $id',
            platformName: 'Board game',
          ),
      ]);
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A household cache holding one household per id in [ids].
class _Households implements HouseholdRepository {
  _Households([this.ids = const []]);

  final List<String> ids;

  @override
  Stream<List<Household>> watchHouseholds() => Stream.multi(
    (stream) => stream.add([
      for (final id in ids)
        Household(
          id: id,
          name: 'Household $id',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
    ]),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// An event cache that answers with nothing, or never answers at all.
class _Events implements EventRepository {
  _Events({this.answers = true});

  final bool answers;
  int watches = 0;

  @override
  Stream<List<EventListItem>> watchAttendingEventListItems() {
    watches++;
    return Stream.multi((stream) {
      if (answers) stream.add(const []);
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A games cache with nothing saved in it, standing for one user's session.
class _GameCache implements GameRepository {
  @override
  Future<List<Game>> getGamesPage({
    int offset = 0,
    required int limit,
    GameSort sort = GameSort.title,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Lists no DataGateways.
class _DataGateways implements DataGatewayRemoteDataSource {
  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) async => PaginatedResult(
    items: const [],
    meta: PaginationMeta(
      page: 1,
      limit: limit,
      total: 0,
      totalPages: 0,
      hasMore: false,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A [ConnectivityService] a test drives by hand. Like the real one, [watch]
/// replays [current] to each new subscriber before any change.
class _Connectivity implements ConnectivityService {
  _Connectivity(this.current);

  @override
  ConnectivityState current;

  final _changes = StreamController<ConnectivityState>.broadcast();

  @override
  Stream<ConnectivityState> watch() async* {
    yield current;
    yield* _changes.stream;
  }

  void change(ConnectivityState next) {
    current = next;
    _changes.add(next);
  }
}

/// Holds whoever the shell last activated, serialized like every real
/// [UserSessionScope], and runs [onActivate] where its installers would run.
class _UserSessionScope implements UserSessionScope {
  _UserSessionScope(this.onActivate, {this.holdActivation});

  final void Function(String userId) onActivate;

  /// What [activate] waits on for a user, as a real scope waits on its
  /// installers. Null for no wait.
  final Future<void>? Function(String userId)? holdActivation;

  String? _activeUserId;
  Future<void> _ops = Future<void>.value();

  @override
  String? get activeUserId => _activeUserId;

  @override
  Future<void> activate(String userId) => _enqueue(() async {
    await holdActivation?.call(userId);
    onActivate(userId);
    _activeUserId = userId;
  });

  @override
  Future<void> deactivate() => _enqueue(() async => _activeUserId = null);

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// One user's session on the server: their caches, as an installer would
/// register them anew for each sign-in.
class _Session {
  _Session({
    required this.games,
    required this.owned,
    required this.households,
    required this.poolCount,
    GameRepository? cache,
  }) : cache = cache ?? _GameCache();

  final GameRepository cache;

  /// What the server shows this user.
  final List<Game> games;
  final _Collection owned;
  final _Households households;
  final int poolCount;
}

/// `BgeApp` composing home's sections (#614, #615, #616, #617): what each is
/// given, and when. What the sections do with it is pinned in `game_catalog`
/// and `game_collection`. What only this file can check is that the session's
/// services reach them, and that one session's state ends with it.
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

  /// Pumps home, in a window narrow enough to stack its sections and tall
  /// enough to show them all. [settle] false is for a section that never stops
  /// animating.
  Future<void> pumpHome(
    WidgetTester tester, {
    GamesRemoteDataSource? games,
    GameRepository? gameCache,
    HouseholdRemoteDataSource? pool,
    GameCollectionRepository? collection,
    GameCollectionHydrationStatus? collectionHydration,
    HouseholdRepository? households,
    HouseholdHydrationStatus? householdHydration,
    EventRepository? events,
    DataGatewayAccess? access,
    ConnectivityService? connectivity,
    bool settle = true,
  }) async {
    useViewSize(tester, const Size(800, 2000));
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          gamesRemoteDataSource: games,
          gameRepository: gameCache,
          householdRemoteDataSource: pool,
          gameCollectionRepository: collection,
          gameCollectionHydrationStatus: collectionHydration,
          householdRepository: households,
          householdHydrationStatus: householdHydration,
          eventRepository: events,
          dataGatewayRemoteDataSource: access == null ? null : _DataGateways(),
          dataGatewayAccess: access,
        ),
      ),
    );
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        rootContainer: connectivity == null
            ? null
            : (DependencyContainerImpl()
                ..registerSingleton<ConnectivityService>(connectivity)),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  GoRouter routerOf(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
          as GoRouter;

  DataGatewayAccess accessFor() {
    final access = DataGatewayAccess(remote: _DataGateways());
    addTearDown(access.dispose);
    return access;
  }

  group('the slots', () {
    testWidgets('every slot filled, in order, for a full session', (
      tester,
    ) async {
      await pumpHome(
        tester,
        games: _GamesRemote([_game('a')]),
        pool: _Pool(gameCount: 3),
        collection: _Collection(['a']),
        households: _Households(['h']),
        events: _Events(),
      );

      double topOf(Type section) => tester.getTopLeft(find.byType(section)).dy;

      expect(topOf(UpcomingEventsSection), lessThan(topOf(StatsCard)));
      expect(topOf(StatsCard), lessThan(topOf(NewestGamesSection)));
      expect(
        topOf(NewestGamesSection),
        lessThan(topOf(SomethingToPlaySection)),
      );
    });

    testWidgets('no games remote: neither shelf', (tester) async {
      await pumpHome(tester, collection: _Collection(['a']));

      expect(find.byType(NewestGamesSection), findsNothing);
      expect(find.byType(SomethingToPlaySection), findsNothing);
      expect(find.byType(StatsCard), findsOneWidget);
    });

    testWidgets('no collection repository: no card', (tester) async {
      await pumpHome(tester, games: _GamesRemote([_game('a')]));

      expect(find.byType(StatsCard), findsNothing);
      expect(find.byType(NewestGamesSection), findsOneWidget);
      expect(find.byType(SomethingToPlaySection), findsOneWidget);
    });

    testWidgets("the shelf draws from the session's pool and own games", (
      tester,
    ) async {
      final pool = _Pool();
      await pumpHome(
        tester,
        games: _GamesRemote(const []),
        pool: pool,
        collection: _Collection(['mine']),
      );

      expect(pool.reads, 1);
      expect(
        find.byKey(SomethingToPlaySection.coverKey('mine')),
        findsOneWidget,
      );
    });
  });

  testWidgets('the connection coming back reaches every section', (
    tester,
  ) async {
    final connectivity = _Connectivity(ConnectivityState.offline);
    await pumpHome(
      tester,
      games: _GamesRemote([_game('a')]),
      pool: _Pool(gameCount: 3),
      collection: _Collection(),
      households: _Households(['h']),
      connectivity: connectivity,
    );
    final newest = find.byKey(NewestGamesSection.coverKey('a'));
    final toPlay = find.byKey(SomethingToPlaySection.coverKey('a'));
    final count = find.text('3 games across your households');
    expect(newest, findsNothing);
    expect(toPlay, findsNothing);
    expect(count, findsNothing);

    connectivity.change(ConnectivityState.online);
    await tester.pumpAndSettle();

    expect(newest, findsOneWidget);
    expect(toPlay, findsOneWidget);
    expect(count, findsOneWidget);
  });

  group('leaving home from a section', () {
    testWidgets('See all opens /games?sort=newest, and browse reads newest', (
      tester,
    ) async {
      final games = _GamesRemote([_game('a')]);
      await pumpHome(tester, games: games);
      games.sorts.clear();

      await tester.tap(find.byKey(NewestGamesSection.linkKey));
      await tester.pumpAndSettle();

      expect(find.byType(GameBrowseScreen), findsOneWidget);
      expect(
        routerOf(tester).state.uri.toString(),
        AppRoutes.gamesSorted(GameSort.newest),
      );
      expect(games.sorts, [GameSort.newest]);

      // A push: the browse screen reads its sort once, when it mounts, and the
      // way back is to the home page it was opened from.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.byType(GameBrowseScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('a cover opens the game, and a game found gone there leaves '
        'both shelves', (tester) async {
      final games = _GamesRemote([_game('a'), _game('b')])..gone.add('a');
      await pumpHome(tester, games: games);

      final newestA = find.byKey(NewestGamesSection.coverKey('a'));
      final toPlayA = find.byKey(SomethingToPlaySection.coverKey('a'));
      final toPlayB = find.byKey(SomethingToPlaySection.coverKey('b'));
      expect(newestA, findsOneWidget);
      expect(toPlayA, findsOneWidget);

      await tester.tap(toPlayB);
      await tester.pumpAndSettle();
      expect(find.byType(GameDetailScreen), findsOneWidget);
      expect(find.byKey(GameDetailScreen.unavailableKey), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(newestA);
      await tester.pumpAndSettle();
      expect(find.byKey(GameDetailScreen.unavailableKey), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(newestA, findsNothing);
      expect(toPlayA, findsNothing);
      expect(find.byKey(NewestGamesSection.coverKey('b')), findsOneWidget);
      expect(toPlayB, findsOneWidget);
    });

    testWidgets('the prompt opens /household', (tester) async {
      await pumpHome(
        tester,
        collection: _Collection(),
        households: _Households(),
      );

      await tester.tap(find.byKey(StatsCard.promptKey));
      await tester.pumpAndSettle();

      expect(find.byType(HouseholdListScreen), findsOneWidget);
      expect(routerOf(tester).state.uri.toString(), AppRoutes.household);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  // A status that is registered must reach the card: with no stream it reads as
  // settled, and the prompt or a "0 games" would flash before the first
  // hydrate lands.
  group('the hydrates', () {
    testWidgets('a household hydrate still running shows no prompt', (
      tester,
    ) async {
      final status = HouseholdHydrationStatus()..started();
      addTearDown(status.close);
      await pumpHome(
        tester,
        collection: _Collection(),
        households: _Households(),
        householdHydration: status,
      );

      expect(find.byKey(StatsCard.promptKey), findsNothing);

      status.finished(HydrateOutcome.complete);
      await tester.pumpAndSettle();

      expect(find.byKey(StatsCard.promptKey), findsOneWidget);
    });

    testWidgets('a collection hydrate still running shows no count', (
      tester,
    ) async {
      final status = GameCollectionHydrationStatus()..started();
      addTearDown(status.close);
      await pumpHome(
        tester,
        collection: _Collection(),
        collectionHydration: status,
      );

      expect(find.byKey(StatsCard.ownedKey), findsNothing);

      status.finished(CollectionHydrateOutcome.complete);
      await tester.pumpAndSettle();

      expect(find.byKey(StatsCard.ownedKey), findsOneWidget);
    });
  });

  group('a server with no games', () {
    final card = find.byKey(NewestGamesSection.emptyActionKey);
    final message = find.byKey(NewestGamesSection.emptyKey);

    testWidgets('read granted, mayChange true: the card, and its action opens '
        'the DataGateway list', (tester) async {
      await pumpHome(
        tester,
        games: _GamesRemote(const []),
        access: accessFor()..readGranted(),
      );

      expect(card, findsOneWidget);

      await tester.tap(card);
      await tester.pumpAndSettle();

      expect(find.byType(DataGatewayListScreen), findsOneWidget);
      expect(
        routerOf(tester).state.uri.toString(),
        AppRoutes.adminDataGateways,
      );
    });

    testWidgets('read denied: the plain message', (tester) async {
      await pumpHome(
        tester,
        games: _GamesRemote(const []),
        access: accessFor()..readDenied(),
      );

      expect(message, findsOneWidget);
      expect(card, findsNothing);
    });

    testWidgets('read unknown: the plain message', (tester) async {
      await pumpHome(
        tester,
        games: _GamesRemote(const []),
        access: accessFor(),
      );

      expect(message, findsOneWidget);
      expect(card, findsNothing);
    });

    testWidgets('no access check registered: the plain message', (
      tester,
    ) async {
      await pumpHome(tester, games: _GamesRemote(const []));

      expect(message, findsOneWidget);
      expect(card, findsNothing);
    });

    testWidgets('mayChange false: the plain message', (tester) async {
      await pumpHome(
        tester,
        games: _GamesRemote(const []),
        access: accessFor()
          ..readGranted()
          ..changeDenied(),
      );

      expect(message, findsOneWidget);
      expect(card, findsNothing);
    });

    testWidgets('access landing swaps message for card with no new read', (
      tester,
    ) async {
      final games = _GamesRemote(const []);
      final pool = _Pool(gameCount: 3);
      final collection = _Collection();
      final events = _Events();
      final access = accessFor();
      await pumpHome(
        tester,
        games: games,
        pool: pool,
        collection: collection,
        households: _Households(['h']),
        events: events,
        access: access,
      );
      expect(message, findsOneWidget);
      expect(card, findsNothing);

      final listReads = games.sorts.length;
      final randomReads = games.randomReads;
      final poolReads = pool.reads;
      final collectionWatches = collection.watches;
      final eventWatches = events.watches;
      final newest = tester.element(message).read<NewestGamesCubit>();
      final stats = tester
          .element(find.byKey(StatsCard.headingKey))
          .read<StatsCubit>();

      access.readGranted();
      await tester.pumpAndSettle();

      expect(card, findsOneWidget);
      expect(games.sorts, hasLength(listReads));
      expect(games.randomReads, randomReads);
      expect(pool.reads, poolReads);
      expect(collection.watches, collectionWatches);
      expect(events.watches, eventWatches);
      expect(tester.element(card).read<NewestGamesCubit>(), same(newest));
      expect(
        tester.element(find.byKey(StatsCard.headingKey)).read<StatsCubit>(),
        same(stats),
      );
    });
  });

  // Owed by #613's reconcile: the pair sit side by side, and neither waits on
  // the other.
  group('events and the card', () {
    testWidgets('events still loading does not hold up the card', (
      tester,
    ) async {
      await pumpHome(
        tester,
        collection: _Collection(['a']),
        events: _Events(answers: false),
        settle: false,
      );

      expect(find.byKey(UpcomingEventsSection.loadingKey), findsOneWidget);
      expect(find.text('1 game in your collection'), findsOneWidget);
    });

    testWidgets('the card failing draws nothing, and does not touch events', (
      tester,
    ) async {
      await pumpHome(
        tester,
        collection: _Collection(const [], true),
        events: _Events(),
      );

      expect(find.byKey(StatsCard.headingKey), findsNothing);
      expect(find.byKey(StatsCard.ownedKey), findsNothing);
      expect(find.byKey(UpcomingEventsSection.emptyKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // On web a sign-in in another tab moves the shared cookie to another user
  // over a live session (#432). The server's remotes outlive that, and the
  // sections' cubits are made once per mount. A session that goes live before
  // the next frame never shows the splash, so home keeps its elements, and
  // only the keys on the session's own caches make the sections new.
  group('another user on the same server', () {
    final cover = NewestGamesSection.coverKey;
    final toPlay = SomethingToPlaySection.coverKey;

    late _GamesRemote server;
    late _Pool pool;
    late FakeAuthRepository repo;
    late _Session first;
    late _Session second;

    /// Signs in as the first user, on a server that answers each user with
    /// their own games.
    Future<void> signedInAsFirstUser(
      WidgetTester tester, {
      Future<void>? Function(String userId)? holdActivation,
      bool sharedGamesCache = false,
    }) async {
      useViewSize(tester, const Size(800, 2000));
      first = _Session(
        games: [_game('first')],
        owned: _Collection(['first', 'first-too']),
        households: _Households(['first-h']),
        poolCount: 3,
      );
      second = _Session(
        games: [_game('second')],
        owned: _Collection(['second']),
        households: _Households(['second-h']),
        poolCount: 5,
        cache: sharedGamesCache ? first.cache : null,
      );
      server = _GamesRemote(const []);
      pool = _Pool();
      repo = FakeAuthRepository(initialSession: sampleSession());

      late final ActiveServer active;
      var current = first;
      final scope = _UserSessionScope((userId) {
        current = userId == 'u1' ? first : second;
        server.games = current.games;
        pool.gameCount = current.poolCount;
        if (userId == 'u1') {
          // A factory each, standing for the scope that a real session pops
          // and registers anew: what the shell resolves is the current
          // user's instance.
          (active.container as DependencyContainerImpl)
            ..registerFactory<GameRepository>(() => current.cache)
            ..registerFactory<GameCollectionRepository>(() => current.owned)
            ..registerFactory<HouseholdRepository>(() => current.households);
        }
      }, holdActivation: holdActivation);
      active = buildActiveServer(
        repo,
        userSessionScope: scope,
        gamesRemoteDataSource: server,
        householdRemoteDataSource: pool,
      );
      final app = AppBootstrapCubit(
        platformBootstrap: FakePlatformBootstrap(
          activeServerScope: FakeActiveServerScope(active),
        ),
        hydratedStorageInitializer: (_) async {},
      );
      addTearDown(app.close);

      await tester.pumpWidget(BgeApp(bootstrapCubit: app));
      await app.initialize();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    }

    void switchToSecondUser() {
      final session = sampleSession();
      repo.emitAuthState(
        AuthStateAuthenticated(
          session: AuthResponse(
            token: null,
            user: AuthUser(
              id: 'u2',
              username: 'other',
              email: 'u2@example.com',
              emailVerified: true,
              createdAt: DateTime(2099),
              updatedAt: DateTime(2099),
            ),
            expiresAt: session.expiresAt,
          ),
        ),
      );
    }

    SomethingToPlayCubit toPlayCubit(WidgetTester tester) => tester
        .element(find.byKey(SomethingToPlaySection.headingKey))
        .read<SomethingToPlayCubit>();

    NewestGamesCubit newestCubit(WidgetTester tester) => tester
        .element(find.byKey(NewestGamesSection.headingKey))
        .read<NewestGamesCubit>();

    StatsCubit statsCubit(WidgetTester tester) =>
        tester.element(find.byKey(StatsCard.headingKey)).read<StatsCubit>();

    /// Puts the first user's rows, a second draw and a count on the page.
    Future<void> firstUserHasLookedAround(WidgetTester tester) async {
      expect(find.byKey(cover('first')), findsOneWidget);
      expect(find.text('2 games in your collection'), findsOneWidget);
      expect(find.text('3 games across your households'), findsOneWidget);

      await tester.tap(find.byKey(SomethingToPlaySection.reshuffleKey));
      await tester.pumpAndSettle();
      expect(
        (toPlayCubit(tester).state as SomethingToPlayReady).draw,
        2,
        reason: 'the draw the second user must not inherit',
      );
    }

    void expectOnlySecondUser(WidgetTester tester) {
      expect(find.byKey(cover('first')), findsNothing);
      expect(find.byKey(toPlay('first')), findsNothing);
      expect(find.byKey(toPlay('first-too')), findsNothing);
      expect(find.text('2 games in your collection'), findsNothing);
      expect(find.text('3 games across your households'), findsNothing);

      expect(find.byKey(cover('second')), findsOneWidget);
      expect(find.text('1 game in your collection'), findsOneWidget);
      expect(find.text('5 games across your households'), findsOneWidget);
      expect((toPlayCubit(tester).state as SomethingToPlayReady).draw, 1);
    }

    testWidgets('another user on the same server gets new sections: no rows, '
        'draw or count carried over', (tester) async {
      await signedInAsFirstUser(tester);
      await firstUserHasLookedAround(tester);
      final oldNewest = newestCubit(tester);
      final oldToPlay = toPlayCubit(tester);
      final oldStats = statsCubit(tester);
      final firstWatches = first.owned.watches;
      expect(second.owned.watches, 0);

      switchToSecondUser();
      await tester.pumpAndSettle();
      // A cubit's close awaits the cancelling of its streams before it marks
      // itself closed, and the fake clock holds that await until real time
      // runs a turn.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));

      expectOnlySecondUser(tester);
      expect(oldNewest.isClosed, isTrue);
      expect(oldToPlay.isClosed, isTrue);
      expect(oldStats.isClosed, isTrue);
      expect(newestCubit(tester), isNot(same(oldNewest)));
      expect(toPlayCubit(tester), isNot(same(oldToPlay)));
      expect(statsCubit(tester), isNot(same(oldStats)));
      expect(first.owned.watches, firstWatches);
      expect(second.owned.watches, greaterThan(0));
    });

    testWidgets("Something to play is keyed on the session's collection, which "
        'is where half of its draw comes from: a new one is a new row even '
        'under the same games cache', (tester) async {
      await signedInAsFirstUser(tester, sharedGamesCache: true);
      await firstUserHasLookedAround(tester);
      final oldToPlay = toPlayCubit(tester);
      expect(find.byKey(toPlay('first')), findsOneWidget);

      switchToSecondUser();
      await tester.pumpAndSettle();

      expect(toPlayCubit(tester), isNot(same(oldToPlay)));
      expect(find.byKey(toPlay('first')), findsNothing);
      expect(find.byKey(toPlay('first-too')), findsNothing);
      expect(find.byKey(toPlay('second')), findsOneWidget);
      expect((toPlayCubit(tester).state as SomethingToPlayReady).draw, 1);
    });

    testWidgets('the same holds when the session starts slowly, behind the '
        'splash', (tester) async {
      final starting = Completer<void>();
      await signedInAsFirstUser(
        tester,
        holdActivation: (userId) => userId == 'u2' ? starting.future : null,
      );
      await firstUserHasLookedAround(tester);

      switchToSecondUser();
      await tester.pump();
      await tester.pump();
      expect(find.byType(HomeScreen), findsNothing);

      starting.complete();
      await tester.pumpAndSettle();

      expectOnlySecondUser(tester);
    });
  });
}
