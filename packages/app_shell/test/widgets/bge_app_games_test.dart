import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

final _catan = Game(
  id: 'g_catan',
  title: 'Catan',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// One game in the catalog, found by every search with one DataGateway
/// result.
class _GamesRemote implements GamesRemoteDataSource {
  /// Games whose detail answers 404, as one deleted since the list loaded.
  final Set<String> gone = {};

  /// When set, every detail waits for it, as on a slow server.
  Completer<GameWithPlatformGames>? held;

  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
  }) async => PaginatedResult(
    items: [_catan],
    meta: const PaginationMeta(
      page: 1,
      limit: 50,
      total: 1,
      totalPages: 1,
      hasMore: false,
    ),
  );

  @override
  Future<GameWithPlatformGames> fetchGame(String id) async {
    final held = this.held;
    if (held != null) return held.future;
    if (gone.contains(id)) throw const GameNotFoundException('404');
    return (game: _catan, platformGames: const <PlatformGameSummary>[]);
  }

  @override
  Future<GameSearchResults> search(
    String query, {
    int limit = GamesRemoteDataSource.searchPageSize,
    int offset = 0,
    Set<ContentType> contentTypes = const {},
    Set<PlatformType> platformTypes = const {},
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
}

/// Lists one DataGateway, named.
class _DataGatewayRemote implements DataGatewayRemoteDataSource {
  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) async => const PaginatedResult(
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

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The Games entry in the home drawer and the screens behind it (#42).
void main() {
  late _MockAppBootstrapCubit cubit;
  late _DataGatewayRemote dataGateways;
  late DataGatewayAccess access;
  late _GamesRemote games;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    dataGateways = _DataGatewayRemote();
    games = _GamesRemote();
    access = DataGatewayAccess(remote: dataGateways);
  });

  tearDown(() => access.dispose());

  Future<void> pumpHome(WidgetTester tester, {bool withGames = true}) async {
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          gamesRemoteDataSource: withGames ? games : null,
          dataGatewayRemoteDataSource: dataGateways,
          dataGatewayAccess: access,
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
    await openGames(tester);

    expect(find.byType(GameBrowseScreen), findsOneWidget);

    await tester.tap(find.byKey(GameBrowseScreen.rowKey('g_catan')));
    await tester.pumpAndSettle();

    expect(find.byType(GameDetailScreen), findsOneWidget);
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
      'user\'s list', (tester) async {
    final repo = FakeAuthRepository(initialSession: sampleSession());
    final app = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        activeServerScope: FakeActiveServerScope(
          buildActiveServer(
            repo,
            gamesRemoteDataSource: games,
            dataGatewayRemoteDataSource: dataGateways,
            dataGatewayAccess: access,
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
    await tester.pump();
    expect(find.byKey(GameDetailScreen.loadingKey), findsOneWidget);
    repo.emitAuthState(const AuthStateUnauthenticated());
    await tester.pumpAndSettle();
    expect(find.byType(GameDetailScreen), findsNothing);

    // The next user opens the catalog, and then the old read answers.
    final first = sampleSession();
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
    access.readGranted();
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    expect(find.textContaining('BoardGameGeek'), findsOneWidget);
  });

  testWidgets('search names no DataGateway for a user who may not', (
    tester,
  ) async {
    access.readDenied();
    await pumpHome(tester);
    await openGames(tester);
    await searchFor(tester, 'catan');

    expect(
      find.byKey(GameSearchScreen.sourceRowKey('dg_bgg', '926')),
      findsOneWidget,
    );
    expect(find.textContaining('BoardGameGeek'), findsNothing);
  });
}
