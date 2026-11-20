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
  Future<List<GameSummary>> Function(int size)? onFetchRandom;
  Future<GameWithPlatformGames> Function(String id)? onFetchGame;
  Future<GameSearchResults> Function(
    String query,
    GameSearchFilter filter,
    // The handler's shape is positional like its neighbours'.
    // ignore: avoid_positional_boolean_parameters
    bool includeExternal,
  )?
  onSearch;
  Future<GameImportReceipt> Function(
    String gatewayId,
    String externalId,
    String correlationId,
  )?
  onStartImport;
  Future<ImportBatch> Function(String batchId)? onFetchImport;

  /// Answers [fetchExpansions]; unscripted, it answers no expansions.
  Future<GameSearchResults> Function(GameExpansionsTarget target)?
  onFetchExpansions;

  /// The targets every [fetchExpansions] asked for, in order.
  final List<GameExpansionsTarget> expansionTargets = [];

  /// The expansions every [startImport] was asked to import with, in order.
  final List<List<String>> importedExpansions = [];

  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
    GameSort sort = GameSort.title,
  }) {
    // Title is the default, so its calls read as they always have.
    calls.add(
      sort == GameSort.title
          ? 'fetchPage($page, $limit)'
          : 'fetchPage($page, $limit, ${sort.name})',
    );
    return _run(onFetchPage, 'fetchPage')(page, limit);
  }

  @override
  Future<List<GameSummary>> fetchRandom({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) {
    calls.add('fetchRandom($size)');
    return _run(onFetchRandom, 'fetchRandom')(size);
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
    GameSearchFilter filter = const GameSearchFilter(),
    bool includeExternal = true,
  }) {
    final described = describeSearch(
      query,
      filter,
      includeExternal: includeExternal,
    );
    calls.add('search($described)');
    return _run(onSearch, 'search')(query, filter, includeExternal);
  }

  @override
  Future<GameSearchResults> fetchExpansions(GameExpansionsTarget target) {
    expansionTargets.add(target);
    calls.add('fetchExpansions($target)');
    return onFetchExpansions?.call(target) ??
        Future.value(const GameSearchResults());
  }

  @override
  Future<GameImportReceipt> startImport({
    required String gatewayId,
    required String externalId,
    required String correlationId,
    List<String> expansionExternalIds = const [],
  }) {
    importedExpansions.add(expansionExternalIds);
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

/// A search as the fakes record it, over REST or the socket alike: [query],
/// then [filter] as ` [content] {platform}`, then `year(…)`, `players(…)` and
/// `time(…)` for each range that narrows, as `min..max`, with `+?` when it
/// keeps unknown values, and ` -external` when it leaves the DataGateways
/// out.
String describeSearch(
  String query,
  GameSearchFilter filter, {
  required bool includeExternal,
}) {
  String names(Iterable<Enum> types) =>
      (types.map((t) => t.name).toList()..sort()).join(',');
  String range(String name, GameSearchRange range) => range.narrows
      ? ' $name(${range.min ?? ''}..${range.max ?? ''}'
            '${range.includeUnknown ? '+?' : ''})'
      : '';

  final GameSearchFilter(:contentTypes, :platformTypes) = filter;
  return [
    query,
    if (contentTypes.isNotEmpty) ' [${names(contentTypes)}]',
    if (platformTypes.isNotEmpty) ' {${names(platformTypes)}}',
    range('year', filter.publishYear),
    range('players', filter.playerCount),
    range('time', filter.playTime),
    if (!includeExternal) ' -external',
  ].join();
}

final _seeded = DateTime.utc(2026, 10);

/// A full game record.
Game game(
  String id, {
  String? title,
  ContentType contentType = ContentType.baseGame,
  List<ExpansionLink> baseGames = const [],
}) => Game(
  id: id,
  title: title ?? 'Game $id',
  contentType: contentType,
  baseGames: baseGames,
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
