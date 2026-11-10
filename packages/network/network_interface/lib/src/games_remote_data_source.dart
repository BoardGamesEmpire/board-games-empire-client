import 'package:models/domain.dart';

import 'package:network_interface/src/paginated_result.dart';

/// One game read by id, with the platform games the server sent beside it
/// (#42).
///
/// Separate values for the reason `GameCollectionWithSummary` gives: they
/// are different records, and the game alone is what the games cache holds.
///
/// `platformGames` are full [PlatformGame] records, in the order the server
/// sent them. The shape is backend#791's, and settled: each row is the
/// platform game's own columns and its platform, whose name is kept as
/// [PlatformGame.platformName]. A full record is what the cache holds, so the
/// detail can cache it and a collection add finds its row (#45).
///
/// A row missing what a [PlatformGame] requires is skipped, not failed, so
/// the game still shows. An empty list means the game is on no platform, or
/// the caller may not read its platform games; a server older than
/// backend#791 sends none at all, which reads the same.
typedef GameWithPlatformGames = ({Game game, List<PlatformGame> platformGames});

/// Remote data source for the server's games: the catalog, one game, and
/// search (#42), and importing a game from a DataGateway (#43).
///
/// Implementations run over a **per-server** authenticated transport, like
/// [DataGatewayRemoteDataSource]: the injected client carries the base URL
/// and the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/game` at `a21cd51e` (`GET /games?sort=` and
/// `GET /games/random` at `c8f42b83`), `libs/api/game-search` at `997cc084`,
/// and `libs/api/game-import` at `83e62bb0`, all under the `api` global
/// prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchPage] | `GET /api/games` | `{ games: [...], pagination }` |
/// | [fetchRandom] | `GET /api/games/random` | `{ games: [...] }` |
/// | `HouseholdRemoteDataSource.fetchGamePoolSample` | `GET /api/households/game-pool/random` | `{ games: [...], gameCount }` |
/// | [fetchGame] | `GET /api/games/:id` | `{ game }` |
/// | [search] | `GET /api/games/search` | `{ correlationId, resultsBySource, errors?, rateLimitedSources?, unavailableSources?, unfilterableSources? }` |
/// | [startImport] | `POST /api/games/import` | `{ message, batchId, baseJobId, expansionJobIds, correlationId }` |
/// | [fetchImport] | `GET /api/games/import/:batchId` | `{ batchId, correlationId, status, jobs: [...] }` |
///
/// The two random reads send each game as the server's game summary: `id`,
/// `title`, `thumbnail` and `description`, the last two nullable (#615).
/// The household's is listed here for that shared shape; its own source
/// carries the rest.
///
/// The two list reads page differently. [fetchPage] is page-based, ordered by
/// title or by newest first (`sort`), then by id, and refuses `?offset=` with
/// a 400. [search] is offset-based, sends no total and no has-more signal,
/// and puts no order on its local half (backend#792). So a caller pages the
/// catalog and reads one page of search.
///
/// ## What the mapping keeps and drops
///
/// Each game is mapped field by field, not through `Game.fromJson`, because
/// `GET /games/:id` sends its relations as nested rows where [Game] has
/// lists of names.
///
/// - **The relation lists are dropped,** categories, mechanics, designers,
///   publishers and tags alike. A catalog row has none, and the cache's write
///   is a full replace, so caching one would empty the lists a detail fetch
///   wrote. Nothing shows them yet.
/// - **A search result keeps** what a row shows and what opening it needs
///   ([GameSearchHit]). It drops the rating, the source URL, the base game's
///   id, each platform's id and the releases.
///
/// Search results name content and platform types two ways: local results
/// use the stored names (`BaseGame`, `Tabletop`) and DataGateway results the
/// proto names (`CONTENT_TYPE_BASE_GAME`, `PLATFORM_TYPE_TABLETOP`). Both are
/// read, until backend#662 settles one.
///
/// ## Search waits for every DataGateway
///
/// The server answers [search] once every DataGateway has, or after 15
/// seconds, dropping any still pending without naming it. Implementations
/// must let a search wait longer than that, not hold it to the transport's
/// default timeout.
///
/// ## Failure classification
///
/// Every transport failure is wrapped as a [GamesRemoteException]; callers
/// never see a raw transport error. The envelope rules are the ones every
/// remote source applies (#350, #365, #253): only the API's own error
/// envelope licenses a conclusion about the caller or a row.
///
/// - [GamesForbiddenException]: a 403 carrying the API's error envelope. A
///   game that exists and the caller may not read is a 403, not a 404, at
///   `GET /games/:id`. The list reads answer a 403 to an actor with no games
///   of its own.
/// - [GameNotFoundException]: a 404 carrying the envelope from [fetchGame].
/// - [GameImportNotFoundException]: a 404 carrying the envelope from
///   [fetchImport].
/// - [GamesRemotePermanentException]: any other 4xx the transient rule below
///   leaves out, and a 2xx whose body cannot be read as the contract above.
/// - [GamesRemoteTransientException]: no response at all, 401, 407, 408, 429,
///   every 5xx, a 403 or 404 without the envelope, a 404 from [fetchPage],
///   [fetchRandom], [search] or [startImport] even with it (a list or write
///   route is never absent, so the route is not deployed), a 409 saying
///   `retryable: true` (a deadlock the server asks the caller to retry), and
///   a 2xx body this device could not decode at all.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: a page, limit or offset out of range, a filter naming an
/// unknown type, a filter range whose minimum is above its maximum or whose
/// bound is past the server's limits, an id that is not one path segment, an
/// empty DataGateway or external id, or a correlation or batch id that is
/// not a UUID.
abstract class GamesRemoteDataSource {
  /// The backend's `limit` ceiling on both list reads
  /// (`DEFAULT_MAX_PAGE_SIZE`). A larger limit is a 400, not clamped.
  static const int maxPageSize = 100;

  /// The backend's depth ceiling (`DEFAULT_MAX_OFFSET`): a catalog page may
  /// not start past this row, and a search offset may not exceed it.
  static const int maxDepth = 100000;

  /// How many results [search] asks each source for by default: the
  /// server's own default for its local half.
  static const int searchPageSize = 20;

  /// The lowest and highest bound a search range may name: the server
  /// carries each as an int32 (#565, #580).
  static const int minRangeBound = -2147483648;
  static const int maxRangeBound = 2147483647;

  /// The fewest players a search's player count may name.
  static const int minPlayerCount = 1;

  /// The shortest play time, in minutes, a search's play time may name.
  static const int minPlayTime = 0;

  /// How many games a random sample asks for by default, and how many the
  /// home page shows in a row (#615). The server's own default.
  static const int defaultSampleSize = 10;

  /// The most games the server sends in one random sample. A larger `size`
  /// is a 400, not clamped.
  static const int maxSampleSize = 50;

  /// One page of the catalog: the live public games and the caller's own,
  /// ordered by [sort], each order ending in the game id.
  ///
  /// Follow [PaginationMeta.hasMore] to the end. [page] is 1-based, [limit]
  /// is in `1..maxPageSize`, and `(page - 1) * limit` may not exceed
  /// [maxDepth].
  ///
  /// [sort] is sent only for [GameSort.newest]: [GameSort.title] is the
  /// server's default, so a request for it is the request this source has
  /// always made.
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = maxPageSize,
    GameSort sort = GameSort.title,
  });

  /// Up to [size] games picked at random, in random order, from the games
  /// [fetchPage] lists for the caller (#615).
  ///
  /// Each is a [GameSummary]: the id, the title and the thumbnail. The
  /// server's description is dropped, because nothing here shows it. Ask
  /// again for a different sample; the server never caches one. A catalog
  /// with fewer than [size] games sends them all, and an empty one sends
  /// none.
  ///
  /// [size] must be in `1..maxSampleSize`, which the server enforces with a
  /// 400, so a size outside it throws [ArgumentError] before any request.
  Future<List<GameSummary>> fetchRandom({int size = defaultSampleSize});

  /// One game, with the platform games the server sends beside it.
  ///
  /// Throws [GameNotFoundException] when there is no game with [id], and
  /// [GamesForbiddenException] when there is one the caller may not read.
  Future<GameWithPlatformGames> fetchGame(String id);

  /// Searches this server and its DataGateways by title.
  ///
  /// [limit] goes to each source, and [offset] skips that many of each
  /// source's results.
  ///
  /// [filter] narrows the search (#474). A type set that is empty does not
  /// narrow; one that names a type keeps only games of it. Neither may name
  /// an `unknown` type, which has no wire name. A range is sent only when it
  /// names a bound, and its include-unknown flag only when set (#565, #580).
  /// Each bound must be an int32, a player count at least [minPlayerCount]
  /// and a play time at least [minPlayTime], and no range may be reversed:
  /// the server answers each with a 400.
  ///
  /// A DataGateway that can't apply the filter's player count or play time
  /// isn't asked, and is named in
  /// [GameSearchResults.unfilterableDataGateways].
  Future<GameSearchResults> search(
    String query, {
    int limit = searchPageSize,
    int offset = 0,
    GameSearchFilter filter = const GameSearchFilter(),
  });

  /// Starts importing the game [externalId] from the DataGateway [gatewayId],
  /// with no expansions and no locale (#43), and answers once the server has
  /// queued it. The import runs on the server: follow it with [fetchImport].
  ///
  /// [correlationId] must be a UUID, which is all the server accepts. Send the
  /// same one again only for a start whose answer never came: the server may
  /// have started that batch.
  Future<GameImportReceipt> startImport({
    required String gatewayId,
    required String externalId,
    required String correlationId,
  });

  /// The import batch [batchId], as it stands now (#43).
  ///
  /// The server sets no deadline on an import, so a caller following one
  /// needs its own. Throws [GameImportNotFoundException] when there is no
  /// such batch, or none of its jobs the caller may read.
  Future<ImportBatch> fetchImport(String batchId);
}

/// Base class for every games remote failure.
sealed class GamesRemoteException implements Exception {
  const GamesRemoteException(this.message, {this.statusCode, this.cause});

  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      // toString names the concrete subclass, so it needs the runtime type.
      // ignore: no_runtimetype_tostring
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The caller may not read this: a 403 from the API itself.
final class GamesForbiddenException extends GamesRemoteException {
  const GamesForbiddenException(super.message, {super.statusCode, super.cause});
}

/// There is no game with this id.
final class GameNotFoundException extends GamesRemoteException {
  const GameNotFoundException(super.message, {super.statusCode, super.cause});
}

/// There is no import batch with this id, or none of its jobs the caller may
/// read (#43).
final class GameImportNotFoundException extends GamesRemoteException {
  const GameImportNotFoundException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The server refused the request, and sending it again will not change that.
final class GamesRemotePermanentException extends GamesRemoteException {
  const GamesRemotePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class GamesRemoteTransientException extends GamesRemoteException {
  const GamesRemoteTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
