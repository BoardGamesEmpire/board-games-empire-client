import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/decode_json_body.dart';

/// What a request's path names, which is what lets an application 404 mean
/// that thing is gone. A list or write route names nothing: see `_send`.
enum _Row { game, importBatch }

/// [GamesRemoteDataSource] over a **per-server** Dio instance (#42, #43).
///
/// Built on the DataGateway source's request plumbing, which is the
/// collection source's (#351): the body is asked for as a `String` with the
/// response type pinned on every request, decoded here after the status is
/// read, and probed for the API's error envelope with a bounded synchronous
/// parse. It does not build or own its Dio; the network installer constructs
/// it from the per-server container.
///
/// Failure taxonomy and mapping per the [GamesRemoteDataSource] contract.
class GamesRemoteDataSourceImpl implements GamesRemoteDataSource {
  const GamesRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _basePath = '/api/games';

  /// How long a search may wait for its answer.
  ///
  /// The server waits for every DataGateway, for up to 15 seconds
  /// (`game-search.service.ts`), and then still has to answer. The factories'
  /// ten-second receive timeout would fail every search a slow DataGateway
  /// holds up, so this one request gets the cutoff plus room for the
  /// server's own work and the transfer.
  static const Duration searchReceiveTimeout = Duration(seconds: 25);

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`. A fresh instance per
  /// call, because `Options` is mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  /// 4xx statuses worth retrying: an expired session (401), proxy
  /// authentication (407), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 407, 408, 429};

  @override
  Future<PaginatedResult<Game>> fetchPage({
    int page = 1,
    int limit = GamesRemoteDataSource.maxPageSize,
  }) async {
    _checkLimit(limit);
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'is 1-based');
    }
    if ((page - 1) * limit > GamesRemoteDataSource.maxDepth) {
      throw ArgumentError.value(
        page,
        'page',
        'starts past row ${GamesRemoteDataSource.maxDepth}, which the server '
            'refuses with a 400',
      );
    }

    const action = 'Game catalog';
    final response = await _send(
      request: () => _dio.get<String>(
        _basePath,
        options: _plainBody,
        queryParameters: {'page': page, 'limit': limit},
      ),
      action: action,
      row: null,
    );

    return _parse(
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'games',
        item: _mapGame,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<GameWithPlatformGames> fetchGame(String id) async {
    _checkGameId(id);

    const action = 'Game fetch';
    final response = await _send(
      request: () => _dio.get<String>('$_basePath/$id', options: _plainBody),
      action: action,
      row: _Row.game,
    );

    return _parse(
      () {
        final row = response.body['game'];
        if (row is! Map<String, dynamic>) {
          throw const FormatException('response is missing a "game" object');
        }
        final game = _mapGame(row);
        return (game: game, platformGames: _mapPlatformGames(row, game));
      },
      action: action,
      status: response.status,
    );
  }

  @override
  Future<GameSearchResults> search(
    String query, {
    int limit = GamesRemoteDataSource.searchPageSize,
    int offset = 0,
    GameSearchFilter filter = const GameSearchFilter(),
  }) async {
    _checkLimit(limit);
    if (offset < 0 || offset > GamesRemoteDataSource.maxDepth) {
      throw ArgumentError.value(
        offset,
        'offset',
        'must be between 0 and ${GamesRemoteDataSource.maxDepth}',
      );
    }
    final GameSearchFilter(:contentTypes, :platformTypes) = filter;
    if (contentTypes.contains(ContentType.unknown)) {
      // The server refuses `Unknown` as a filter: it names no kind of game.
      throw ArgumentError.value(
        contentTypes,
        'contentTypes',
        'cannot name ContentType.unknown',
      );
    }
    if (platformTypes.contains(PlatformType.unknown)) {
      throw ArgumentError.value(
        platformTypes,
        'platformTypes',
        'cannot name PlatformType.unknown',
      );
    }
    _checkRange(
      filter.publishYear,
      'publishYear',
      lowest: GamesRemoteDataSource.minRangeBound,
    );
    _checkRange(
      filter.playerCount,
      'playerCount',
      lowest: GamesRemoteDataSource.minPlayerCount,
    );
    _checkRange(
      filter.playTime,
      'playTime',
      lowest: GamesRemoteDataSource.minPlayTime,
    );

    const action = 'Game search';
    final response = await _send(
      request: () => _dio.get<String>(
        '$_basePath/search',
        options: _plainBody.copyWith(receiveTimeout: searchReceiveTimeout),
        queryParameters: {
          'query': query,
          'limit': limit,
          'offset': offset,
          // Comma-separated: the server's list transform reads that and the
          // repeated form alike, and this one does not depend on how the
          // injected Dio formats a list.
          if (contentTypes.isNotEmpty)
            'contentTypes': contentTypes.map((t) => t.toWire()).join(','),
          if (platformTypes.isNotEmpty)
            'platformTypes': platformTypes.map((t) => t.toWire()).join(','),
          ..._rangeParams('publishYear', filter.publishYear),
          ..._rangeParams('playerCount', filter.playerCount),
          ..._rangeParams('playTime', filter.playTime),
        },
      ),
      action: action,
      row: null,
    );

    return _parse(
      () => _mapSearchResults(response.body),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<GameImportReceipt> startImport({
    required String gatewayId,
    required String externalId,
    required String correlationId,
  }) async {
    if (gatewayId.isEmpty) {
      throw ArgumentError.value(gatewayId, 'gatewayId', 'is empty');
    }
    if (externalId.isEmpty) {
      throw ArgumentError.value(externalId, 'externalId', 'is empty');
    }
    _checkUuid(correlationId, 'correlationId');

    const action = 'Game import start';
    final response = await _send(
      request: () => _dio.post<String>(
        '$_basePath/import',
        options: _plainBody,
        // No `expansionExternalIds` and no `locale`: both are optional on the
        // server, and the base game alone, with no locale, is what #43
        // imports.
        data: {
          'gatewayId': gatewayId,
          'externalId': externalId,
          'correlationId': correlationId,
        },
      ),
      action: action,
      row: null,
    );

    return _parse(
      () => GameImportReceipt(
        batchId: response.body['batchId'] as String,
        baseJobId: response.body['baseJobId'] as String,
        correlationId: response.body['correlationId'] as String,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<ImportBatch> fetchImport(String batchId) async {
    // The server's ParseUUIDPipe refuses anything else with a 400, and the id
    // goes into the path as it stands.
    _checkUuid(batchId, 'batchId');

    const action = 'Game import poll';
    final response = await _send(
      request: () =>
          _dio.get<String>('$_basePath/import/$batchId', options: _plainBody),
      action: action,
      row: _Row.importBatch,
    );

    return _parse(
      () => _mapImportBatch(response.body),
      action: action,
      status: response.status,
    );
  }

  // ── Request plumbing ────────────────────────────────────────────────

  /// Sends [request] and returns its decoded body, having converted every
  /// failure into a [GamesRemoteException].
  ///
  /// [row] is what the path names, which is what lets an application 404 mean
  /// that it is gone. Null for a list or write route: those are never absent,
  /// so their 404 means the route is not deployed.
  Future<({Map<String, dynamic> body, int status})> _send({
    required Future<Response<String>> Function() request,
    required String action,
    required _Row? row,
  }) async {
    late final Response<String> response;
    try {
      response = await request();
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action, row: row);
    } on Object catch (error) {
      // Nothing else should escape Dio. `Object`, not `Exception`, so an
      // `Error` cannot break the "no raw transport error" promise either.
      throw GamesRemoteTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw GamesRemoteTransientException('$action returned no status');
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(
        status,
        '$action returned $status',
        cause: null,
        row: row,
        body: response.data,
      );
    }

    final raw = response.data;
    if (raw == null || raw.isEmpty) {
      throw GamesRemotePermanentException(
        '$action returned an empty body',
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = await decodeJsonBody(raw);
    } on FormatException catch (error) {
      throw GamesRemotePermanentException(
        '$action returned a body that is not JSON',
        statusCode: status,
        cause: error,
      );
    } on Object catch (error) {
      // The decode could not run (an isolate that would not spawn), which
      // says nothing about the response. See the collection source (#297).
      throw GamesRemoteTransientException(
        '$action could not be decoded',
        statusCode: status,
        cause: error,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw GamesRemotePermanentException(
        '$action returned a body that is not a JSON object',
        statusCode: status,
      );
    }
    return (body: decoded, status: status);
  }

  /// A 2xx whose body cannot be mapped is permanent: the same request returns
  /// the same body.
  T _parse<T>(T Function() map, {required String action, required int status}) {
    try {
      return map();
    } on Object catch (error) {
      throw GamesRemotePermanentException(
        'Failed to parse the $action response: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  // ── Games ───────────────────────────────────────────────────────────

  /// Maps a game row, a catalog row or the detail's, field by field.
  ///
  /// The relation lists stay empty: see "What the mapping keeps and drops" on
  /// [GamesRemoteDataSource].
  static Game _mapGame(Map<String, dynamic> json) => Game(
    id: json['id'] as String,
    title: json['title'] as String,
    subtitle: json['subtitle'] as String?,
    description: json['description'] as String?,
    // The column can hold an empty string: the server's own search reads
    // one as no thumbnail.
    image: _nonEmpty(json['image']),
    thumbnail: _nonEmpty(json['thumbnail']),
    publishYear: json['publishYear'] as int?,
    minPlayers: json['minPlayers'] as int?,
    maxPlayers: json['maxPlayers'] as int?,
    minPlayTime: json['minPlayTime'] as int?,
    maxPlayTime: json['maxPlayTime'] as int?,
    minAge: json['minAge'] as int?,
    // Prisma `Float` columns: JSON writes 3.0 as 3, which decodes as an int.
    complexity: (json['complexity'] as num?)?.toDouble(),
    totalPlayCount: json['totalPlayCount'] as int? ?? 0,
    averageRating: (json['averageRating'] as num?)?.toDouble(),
    bayesRating: (json['bayesRating'] as num?)?.toDouble(),
    ratingsCount: json['ratingsCount'] as int?,
    ownedByCount: json['ownedByCount'] as int? ?? 0,
    contentType: ContentType.fromWire(json['contentType'] as String),
    reach: _reach(json['reach']),
    createdById: json['createdById'] as String?,
    deletedAt: _date(json['deletedAt']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  /// A missing reach, or one this client does not know, reads as unknown
  /// rather than failing the page the game is on. Nothing decides a read by
  /// it: the cache answers by what the server sent each user (#434). A strict
  /// read here is how a renamed field failed every catalog page (#602).
  static Reach _reach(Object? wire) =>
      wire is String ? Reach.fromWire(wire) : Reach.unknown;

  static DateTime? _date(Object? wire) =>
      wire is String ? DateTime.parse(wire) : null;

  /// The detail's `platformGames`, read when the server sends them
  /// (backend#791) and empty until then.
  ///
  /// Read leniently, because backend#791 has not settled the shape: a row
  /// without its id and its platform's id and name, which is what that issue
  /// asks for, is skipped rather than failing the game it came with. The game
  /// is what the detail screen is for, and a strict read here would turn
  /// every detail into the cached copy if the shape lands differently.
  static List<PlatformGameSummary> _mapPlatformGames(
    Map<String, dynamic> row,
    Game game,
  ) {
    final rows = row['platformGames'];
    if (rows is! List) return const [];

    final parent = GameSummary(
      id: game.id,
      title: game.title,
      subtitle: game.subtitle,
      image: game.image,
      thumbnail: game.thumbnail,
    );
    return [
      for (final entry in rows)
        if (entry case {
          'id': final String id,
          'platform': {
            'id': final String platformId,
            'name': final String name,
          },
        })
          PlatformGameSummary(
            id: id,
            platformId: platformId,
            platformName: name,
            image: _nonEmpty(entry['image']),
            thumbnail: _nonEmpty(entry['thumbnail']),
            game: parent,
          ),
    ];
  }

  // ── Search ──────────────────────────────────────────────────────────

  /// The server's name for this half of its results.
  static const String _localSource = 'local';

  static GameSearchResults _mapSearchResults(Map<String, dynamic> body) {
    final bySource = body['resultsBySource'];
    if (bySource is! Map<String, dynamic>) {
      throw const FormatException(
        'response is missing the "resultsBySource" object',
      );
    }

    List<GameSearchHit> hits(Object? rows) => [
      for (final row in (rows! as List).cast<Map<String, dynamic>>())
        _mapHit(row),
    ];

    final errors = body['errors'] as Map<String, dynamic>? ?? const {};
    return GameSearchResults(
      local: bySource.containsKey(_localSource)
          ? hits(bySource[_localSource])
          : const [],
      byDataGateway: {
        for (final entry in bySource.entries)
          if (entry.key != _localSource) entry.key: hits(entry.value),
      },
      failedDataGateways: errors.keys.toSet(),
      rateLimitedDataGateways: _sources(body['rateLimitedSources']),
      unavailableDataGateways: _sources(body['unavailableSources']),
      unfilterableDataGateways: _sources(body['unfilterableSources']),
    );
  }

  static Set<String> _sources(Object? wire) =>
      wire == null ? const {} : (wire as List).cast<String>().toSet();

  static GameSearchHit _mapHit(Map<String, dynamic> json) => GameSearchHit(
    externalId: json['externalId'] as String,
    title: json['title'] as String,
    contentType: _searchContentType(json['contentType'] as String),
    // The server's id only means "on this server" alongside `inSystem`.
    gameId: json['inSystem'] == true ? json['gameId'] as String? : null,
    yearPublished: json['yearPublished'] as int?,
    minPlayers: json['minPlayers'] as int?,
    maxPlayers: json['maxPlayers'] as int?,
    // A DataGateway's unset proto string arrives as "", not absent.
    thumbnailUrl: _nonEmpty(json['thumbnailUrl']),
    platforms: [
      for (final p
          in (json['platforms'] as List? ?? const [])
              .cast<Map<String, dynamic>>())
        GameSearchPlatform(
          name: p['name'] as String,
          abbreviation: _nonEmpty(p['abbreviation']),
          platformType: _searchPlatformType(p['platformType'] as String),
        ),
    ],
  );

  static String? _nonEmpty(Object? wire) =>
      wire is String && wire.isNotEmpty ? wire : null;

  /// The proto name of each content type a DataGateway result may carry
  /// (`bge.gateway.v1.ContentType`), with its stored name.
  static const Map<String, String> _protoContentTypes = {
    'CONTENT_TYPE_BASE_GAME': 'BaseGame',
    'CONTENT_TYPE_EXPANSION': 'Expansion',
    'CONTENT_TYPE_DLC': 'DLC',
    'CONTENT_TYPE_STANDALONE_EXPANSION': 'StandaloneExpansion',
    'CONTENT_TYPE_ACCESSORY': 'Accessory',
    'CONTENT_TYPE_BUNDLE': 'Bundle',
    'CONTENT_TYPE_REMAKE': 'Remake',
    'CONTENT_TYPE_REMASTER': 'Remaster',
    'CONTENT_TYPE_EXPANDED_EDITION': 'ExpandedEdition',
    'CONTENT_TYPE_PORT': 'Port',
    'CONTENT_TYPE_MOD': 'Mod',
  };

  /// As [_protoContentTypes], for `bge.gateway.v1.PlatformType`.
  static const Map<String, String> _protoPlatformTypes = {
    'PLATFORM_TYPE_TABLETOP': 'Tabletop',
    'PLATFORM_TYPE_CONSOLE': 'Console',
    'PLATFORM_TYPE_PORTABLE': 'Portable',
    'PLATFORM_TYPE_PC': 'PC',
    'PLATFORM_TYPE_MOBILE': 'Mobile',
    'PLATFORM_TYPE_ARCADE': 'Arcade',
    'PLATFORM_TYPE_OTHER': 'Other',
  };

  /// Reads either naming scheme (backend#662). An unspecified or
  /// unrecognised proto name falls through to `unknown`, as an unknown stored
  /// name does.
  static ContentType _searchContentType(String wire) =>
      ContentType.fromWire(_protoContentTypes[wire] ?? wire);

  static PlatformType _searchPlatformType(String wire) =>
      PlatformType.fromWire(_protoPlatformTypes[wire] ?? wire);

  // ── Import ──────────────────────────────────────────────────────────

  /// Maps a polled batch field by field, as `toBatchDto` builds it.
  static ImportBatch _mapImportBatch(Map<String, dynamic> json) => ImportBatch(
    batchId: json['batchId'] as String,
    correlationId: json['correlationId'] as String,
    status: ImportBatchStatus.fromWire(json['status'] as String),
    jobs: [
      for (final row in (json['jobs'] as List).cast<Map<String, dynamic>>())
        _mapImportJob(row),
    ],
  );

  /// Maps one job, as `toJobDto` builds it. A field the server leaves out
  /// until the job has a result reads as absent.
  ///
  /// Not read: `parentJobId` and `requestedExpansions`, which only matter to
  /// a batch with expansions, and the `thumbnail`, `error` message and times,
  /// which nothing shows.
  static ImportJob _mapImportJob(Map<String, dynamic> json) => ImportJob(
    jobId: json['jobId'] as String,
    status: ImportJobStatus.fromWire(json['status'] as String),
    isExpansion: json['isExpansion'] as bool,
    externalId: json['externalId'] as String,
    gameId: json['gameId'] as String?,
    gameTitle: json['gameTitle'] as String?,
    platformGames: [
      for (final pg
          in (json['platformGames'] as List? ?? const [])
              .cast<Map<String, dynamic>>())
        ImportPlatformGame(
          platformId: pg['platformId'] as String,
          platformGameId: pg['platformGameId'] as String,
        ),
    ],
    errorCode: switch (json['errorCode'] as String?) {
      final code? => ImportErrorCode.fromWire(code),
      null => null,
    },
  );

  // ── Guards: requests the server is guaranteed to reject ─────────────

  /// One path segment of URL-safe characters: a game id that can only reach
  /// the route it names. Every id the server mints is a cuid2, which this
  /// accepts. The collection remote's rule (#121).
  static final RegExp _wellFormedId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// The id goes into the path as it stands, so one that could leave the
  /// game route is refused before the request: its 404 would read as a
  /// missing game.
  void _checkGameId(String id) {
    if (!_wellFormedId.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'is not a well-formed game id, so the request could reach another '
            'route',
      );
    }
  }

  /// A UUID of any version, which is what the import routes accept for a
  /// correlation id (`@IsUUID`) and a batch id (`ParseUUIDPipe`).
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  void _checkUuid(String value, String name) {
    if (!_uuid.hasMatch(value)) {
      throw ArgumentError.value(
        value,
        name,
        'is not a UUID, which the server refuses with a 400',
      );
    }
  }

  /// Refuses a [range] the server would answer with a 400: a bound below
  /// [lowest] or past an int32, or a minimum above the maximum.
  static void _checkRange(
    GameSearchRange range,
    String name, {
    required int lowest,
  }) {
    for (final bound in [range.min, range.max]) {
      if (bound != null &&
          (bound < lowest || bound > GamesRemoteDataSource.maxRangeBound)) {
        throw ArgumentError.value(
          range,
          name,
          'bounds must be between $lowest and '
          '${GamesRemoteDataSource.maxRangeBound}',
        );
      }
    }
    if (range.isReversed) {
      throw ArgumentError.value(range, name, 'min is above max');
    }
  }

  /// [range]'s query fields, named from [prefix]: none without a bound, and
  /// the include-unknown flag only when set, as `true`.
  static Map<String, Object> _rangeParams(
    String prefix,
    GameSearchRange range,
  ) => {
    if (range.narrows) ...{
      '${prefix}Min': ?range.min,
      '${prefix}Max': ?range.max,
      if (range.includeUnknown) '${prefix}IncludeUnknown': 'true',
    },
  };

  void _checkLimit(int limit) {
    const maxPageSize = GamesRemoteDataSource.maxPageSize;
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $maxPageSize (the server rejects a larger '
            'page rather than clamping it)',
      );
    }
  }

  // ── Failure classification ──────────────────────────────────────────

  GamesRemoteException _classifyDioException(
    DioException error, {
    required String action,
    required _Row? row,
  }) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        '$action failed with status $status',
        cause: error,
        row: row,
        body: error.response?.data,
      );
    }
    return GamesRemoteTransientException('$action failed', cause: error);
  }

  GamesRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
    required _Row? row,
    required Object? body,
  }) {
    if (status >= 500 || _retryable4xx.contains(status)) {
      return GamesRemoteTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }

    // Every answer below is a conclusion about the caller or about a game,
    // and only the application's own envelope licenses one. A proxy or WAF
    // answers 403 and 404 too (#350, #365, #253).
    final fromApi = isApiErrorEnvelope(body, status);

    if (status == 403) {
      return fromApi
          ? GamesForbiddenException(message, cause: cause, statusCode: status)
          : GamesRemoteTransientException(
              '$message; the request did not reach the API',
              cause: cause,
              statusCode: status,
            );
    }
    if (status == 404) {
      // Nest answers an unregistered route with this same envelope, so on a
      // list or write route even an application 404 means "not deployed".
      final GamesRemoteException? gone = !fromApi
          ? null
          : switch (row) {
              _Row.game => GameNotFoundException(
                message,
                cause: cause,
                statusCode: status,
              ),
              _Row.importBatch => GameImportNotFoundException(
                message,
                cause: cause,
                statusCode: status,
              ),
              null => null,
            };
      return gone ??
          GamesRemoteTransientException(
            '$message; the route was not reachable',
            cause: cause,
            statusCode: status,
          );
    }
    if (status >= 400) {
      return GamesRemotePermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A 1xx or 3xx surfaced by a permissive validateStatus carries no
    // rejection.
    return GamesRemoteTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
