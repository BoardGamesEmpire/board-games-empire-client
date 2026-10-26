import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [GamesRemoteDataSource] whose every answer the test scripts.
///
/// Each method records its call in [calls] and then runs the matching
/// handler. An unscripted call throws [StateError], so a test can't pass by
/// reaching a route it never meant to.
class FakeGamesRemote implements GamesRemoteDataSource {
  final List<String> calls = [];

  Future<PaginatedResult<Game>> Function(int page, int limit)? onFetchPage;
  Future<GameWithPlatformGames> Function(String id)? onFetchGame;
  Future<GameSearchResults> Function(
    String query,
    Set<ContentType> contentTypes,
  )?
  onSearch;
  Future<GameImportReceipt> Function(
    String gatewayId,
    String externalId,
    String correlationId,
  )?
  onStartImport;
  Future<ImportBatch> Function(String batchId)? onFetchImport;

  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
  }) {
    calls.add('fetchPage($page, $limit)');
    return _run(onFetchPage, 'fetchPage')(page, limit);
  }

  @override
  Future<GameWithPlatformGames> fetchGame(String id) {
    calls.add('fetchGame($id)');
    return _run(onFetchGame, 'fetchGame')(id);
  }

  @override
  Future<GameSearchResults> search(
    String query, {
    int limit = GamesRemoteDataSource.searchPageSize,
    int offset = 0,
    Set<ContentType> contentTypes = const {},
    Set<PlatformType> platformTypes = const {},
  }) {
    String names(Iterable<Enum> types) =>
        (types.map((t) => t.name).toList()..sort()).join(',');
    final content = contentTypes.isEmpty ? '' : ' [${names(contentTypes)}]';
    final platform = platformTypes.isEmpty ? '' : ' {${names(platformTypes)}}';
    calls.add('search($query$content$platform)');
    return _run(onSearch, 'search')(query, contentTypes);
  }

  @override
  Future<GameImportReceipt> startImport({
    required String gatewayId,
    required String externalId,
    required String correlationId,
  }) {
    calls.add('startImport($gatewayId/$externalId $correlationId)');
    return _run(onStartImport, 'startImport')(
      gatewayId,
      externalId,
      correlationId,
    );
  }

  @override
  Future<ImportBatch> fetchImport(String batchId) {
    calls.add('fetchImport($batchId)');
    return _run(onFetchImport, 'fetchImport')(batchId);
  }

  static T _run<T>(T? handler, String name) =>
      handler ?? (throw StateError('$name was not scripted'));
}

final _seeded = DateTime.utc(2026, 10, 1);

/// A full game record.
Game game(
  String id, {
  String? title,
  ContentType contentType = ContentType.baseGame,
}) => Game(
  id: id,
  title: title ?? 'Game $id',
  contentType: contentType,
  createdAt: _seeded,
  updatedAt: _seeded,
);

/// One catalog page.
PaginatedResult<Game> pageOf(
  List<Game> games, {
  int page = 1,
  int limit = 2,
  bool hasMore = false,
}) => PaginatedResult(
  items: games,
  meta: PaginationMeta(
    page: page,
    limit: limit,
    total: games.length,
    totalPages: 1,
    hasMore: hasMore,
  ),
);

/// A search result. [gameId] marks one the server holds.
GameSearchHit hit(
  String externalId, {
  String? gameId,
  String? title,
  ContentType contentType = ContentType.baseGame,
}) => GameSearchHit(
  externalId: externalId,
  title: title ?? 'Hit $externalId',
  contentType: contentType,
  gameId: gameId,
);

/// The remote's answer when the server could not be reached.
GamesRemoteException unreachable() =>
    const GamesRemoteTransientException('unreachable');
