import 'package:models/domain.dart';

import 'paginated_result.dart';

/// One game read by id, with the platform games the server sent beside it
/// (#42).
///
/// Separate values for the reason [GameCollectionWithSummary] gives: they
/// are different records, and the game alone is what the games cache holds.
///
/// [platformGames] is empty until backend#791 ships, because `GET /games/:id`
/// sends none yet. Each is a [PlatformGameSummary]: the id a collection add
/// needs (#45) and the platform's name, which is what the detail screen
/// lists. That is all backend#791 asks the server for, so a full
/// [PlatformGame], which needs the server's timestamps too, cannot be read
/// from it. A row without even that much is skipped, not failed.
typedef GameWithPlatformGames = ({
  Game game,
  List<PlatformGameSummary> platformGames,
});

/// Remote data source for the server's games: the catalog, one game, and
/// search (#42), and importing a game from a DataGateway (#43).
///
/// Implementations run over a **per-server** authenticated transport, like
/// [DataGatewayRemoteDataSource]: the injected client carries the base URL
/// and the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/game` and `libs/api/game-search` at `a21cd51e`, and
/// `libs/api/game-import` at `83e62bb0`, all under the `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchPage] | `GET /api/games` | `{ games: [...], pagination }` |
/// | [fetchGame] | `GET /api/games/:id` | `{ game }` |
/// | [search] | `GET /api/games/search` | `{ correlationId, resultsBySource, errors?, rateLimitedSources?, unavailableSources? }` |
/// | [startImport] | `POST /api/games/import` | `{ message, batchId, baseJobId, expansionJobIds, correlationId }` |
/// | [fetchImport] | `GET /api/games/import/:batchId` | `{ batchId, correlationId, status, jobs: [...] }` |
///
/// The two list reads page differently. [fetchPage] is page-based, ordered by
/// title and then id, and refuses `?offset=` with a 400. [search] is
/// offset-based, sends no total and no has-more signal, and puts no order on
/// its local half (backend#792). So a caller pages the catalog and reads one
/// page of search.
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
/// never see a raw transport error. The envelope rules are the DataGateway
/// source's (#350, #365, #253): only the API's own error envelope licenses a
/// conclusion about the caller or a row.
///
/// - [GamesForbiddenException]: a 403 carrying the API's error envelope. A
///   game that exists and the caller may not read is a 403, not a 404, at
///   `GET /games/:id`.
/// - [GameNotFoundException]: a 404 carrying the envelope from [fetchGame].
/// - [GameImportNotFoundException]: a 404 carrying the envelope from
///   [fetchImport].
/// - [GamesRemotePermanentException]: any other 4xx the transient rule below
///   leaves out, and a 2xx whose body cannot be read as the contract above.
/// - [GamesRemoteTransientException]: no response at all, 401, 407, 408, 429,
///   every 5xx, a 403 or 404 without the envelope, a 404 from [fetchPage],
///   [search] or [startImport] even with it (a list or write route is never
///   absent, so the route is not deployed), and a 2xx body this device could
///   not decode at all.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: a page, limit or offset out of range, a filter naming an
/// unknown type, an id that is not one path segment, an empty DataGateway or
/// external id, or a correlation or batch id that is not a UUID.
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

  /// One page of the catalog: the live public games and the caller's own,
  /// ordered by title and then id.
  ///
  /// Follow [PaginationMeta.hasMore] to the end. [page] is 1-based, [limit]
  /// is in `1..maxPageSize`, and `(page - 1) * limit` may not exceed
  /// [maxDepth].
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = maxPageSize,
  });

  /// One game, with the platform games the server sends beside it.
  ///
  /// Throws [GameNotFoundException] when there is no game with [id], and
  /// [GamesForbiddenException] when there is one the caller may not read.
  Future<GameWithPlatformGames> fetchGame(String id);

  /// Searches this server and its DataGateways by title.
  ///
  /// [limit] goes to each source, and [offset] skips that many of each
  /// source's results. A filter set that is empty does not narrow; one that
  /// names a type keeps only games of it. Neither may name an `unknown`
  /// type, which has no wire name.
  Future<GameSearchResults> search(
    String query, {
    int limit = searchPageSize,
    int offset = 0,
    Set<ContentType> contentTypes = const {},
    Set<PlatformType> platformTypes = const {},
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
