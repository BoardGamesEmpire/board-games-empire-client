import 'package:dio/dio.dart';
import 'package:dio_network/src/games/game_summary_json.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// What a 404 means for the request that produced it (#253 **D6**).
///
/// The API collapses missing, foreign and out-of-scope rows into one 404, so
/// the status alone cannot say whether the operation failed, had already
/// succeeded, or never reached the endpoint at all. The **request** can:
///
/// - [alreadyRemoved] — a `DELETE`. The backend's delete filter includes
///   `deletedAt: null`, so a re-sent removal 404s from a server that has
///   already done the work. Completion, not failure.
/// - [missingRow] — a single-entry read, a patch, or an add. The row (or, for
///   an add, the platform game / release) genuinely does not exist for this
///   actor. Permanent.
/// - [unreachableEndpoint] — the **collection list**. An authenticated user's
///   collection is never absent: the route always exists, and an empty
///   collection is a 200 with an empty array. So a 404 here is a routing or
///   deployment fault — a path prefix the server does not serve, an API not
///   deployed yet, a proxy misconfiguration — none of which the client can fix
///   and all of which are fixed server-side. Transient, so a hydrate retries
///   once the server is right instead of failing forever.
enum _NotFoundMeaning { missingRow, alreadyRemoved, unreachableEndpoint }

/// [GameCollectionRemoteDataSource] over a **per-server** Dio instance (#253).
///
/// Paths are relative — the per-server Dio carries the base URL (path-prefix
/// deployments included). The BetterAuth session the endpoints require is
/// attached below this class: by the per-server auth plumbing
/// (TokenInterceptor) on native, and by the browser, as its session cookie,
/// on web. This class adds no auth handling of its own; it is constructed
/// from the per-server container by the network installer, so like
/// `HouseholdRemoteDataSourceImpl` it does **not** build or own its Dio and is
/// intentionally not an injectable global singleton.
///
/// Reading of the answer and its failures is shared; see the library doc in
/// `remote_failure.dart`. What is the collection's own lives on
/// [_CollectionFailures].
///
/// Failure taxonomy per the [GameCollectionRemoteDataSource] contract — see
/// that interface for the transient / permanent split and the 404 contexts.
/// Argument violations are the one exception to it: they surface as
/// [ArgumentError], unwrapped, because they are the caller's bug rather than
/// the server's answer.
class GameCollectionRemoteDataSourceImpl
    implements GameCollectionRemoteDataSource {
  const GameCollectionRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _basePath = '/api/game-collections';

  /// Pinned on every request rather than inherited from the injected Dio.
  ///
  /// Asking for `Response<String>` is not sufficient on its own. `fetch`'s
  /// forcing block is skipped when the instance's `responseType` is already
  /// `bytes`/`stream` (`dio_mixin.dart:419-421`), and `assureResponse` then
  /// casts the body to `String` anyway (`:807`) — a `TypeError` escaping as
  /// `DioException(type: unknown)` with no response attached, which is this
  /// class's own status-losing failure arriving by a different route. `Object?`
  /// was immune to that cast because every value satisfies it; `String` is not,
  /// so the move to a typed body makes the pin a requirement rather than a
  /// hardening (#351, #360).
  ///
  /// A fresh instance per call: `Options` is mutable, and one shared across
  /// five endpoints is a shared mutable default waiting to be edited.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<PaginatedResult<GameCollectionWithSummary>> fetchCollectionPage({
    int page = 1,
    int limit = GameCollectionRemoteDataSource.maxPageSize,
    bool includeDeleted = false,
    bool deletedOnly = false,
    GameMedium? medium,
    bool? favorite,
    DateTime? updatedSince,
  }) async {
    _checkPaging(page: page, limit: limit);

    const action = 'Collection list';
    // A list route that 404s was never reached — see _NotFoundMeaning.
    const failures = _CollectionFailures(_NotFoundMeaning.unreachableEndpoint);
    final response = await sendForJson(
      () => _dio.get<String>(
        _basePath,
        options: _plainBody,
        queryParameters: {
          'page': page,
          'limit': limit,
          // The false cases are the server's own defaults, so omitting them
          // keeps the query string to what the caller actually asked for.
          if (includeDeleted) 'includeDeleted': true,
          if (deletedOnly) 'deletedOnly': true,
          'medium': ?medium?.toWire(),
          'favorite': ?favorite,
          'updatedSince': ?updatedSince?.toUtc().toIso8601String(),
        },
      ),
      action: action,
      family: failures,
    );

    // The envelope parse and the row mapping share one permanent
    // classification: a missing array, a missing or partial `pagination`, and
    // a row the mapper cannot read — its summary included (#259) — are all a
    // 2xx this source cannot map.
    return parseRemote(
      failures,
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'collections',
        item: _mapEntryWithSummary,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<GameCollectionWithSummary> fetchEntry(String id) async {
    _checkEntryId(id);

    const action = 'Collection fetch';
    const failures = _CollectionFailures(_NotFoundMeaning.missingRow);
    final response = await sendForJson(
      () => _dio.get<String>(
        '$_basePath/$id',
        options: _plainBody,
        queryParameters: const {},
      ),
      action: action,
      family: failures,
    );
    return _singleEntry(
      response,
      action: action,
      family: failures,
      map: _mapEntryWithSummary,
    );
  }

  @override
  Future<GameCollection> addToCollection({
    required String platformGameId,
    required GameMedium medium,
    String? releaseId,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
  }) async {
    _checkQuantity(quantity);

    const action = 'Collection add';
    const failures = _CollectionFailures(_NotFoundMeaning.missingRow);
    final response = await sendForJson(
      () => _dio.post<String>(
        _basePath,
        options: _plainBody,
        data: {
          'platformGameId': platformGameId,
          'medium': medium.toWire(),
          // Null is omitted, never sent — see the class doc on the interface.
          'releaseId': ?releaseId,
          'quantity': ?quantity,
          'rating': ?rating,
          'comment': ?comment,
          'favorite': ?favorite,
          'playAgain': ?playAgain,
        },
      ),
      action: action,
      family: failures,
    );
    return _singleEntry(
      response,
      action: action,
      family: failures,
      map: _mapEntry,
    );
  }

  @override
  Future<GameCollection> updateEntry({
    required String id,
    int? quantity,
    int? rating,
    String? comment,
    bool? favorite,
    bool? playAgain,
    String? releaseId,
  }) async {
    _checkEntryId(id);
    _checkQuantity(quantity);

    // Omitted, not nulled: on this endpoint an explicit null CLEARS the field,
    // while the client's own contract is that null means leave-unchanged.
    // `playCount` / `lastPlayed` / `platformGameId` / `medium` are absent from
    // this method's parameters entirely — the server rejects them under
    // `forbidNonWhitelisted`, so there is nothing to omit here (#253 D3, #258).
    final body = <String, dynamic>{
      'quantity': ?quantity,
      'rating': ?rating,
      'comment': ?comment,
      'favorite': ?favorite,
      'playAgain': ?playAgain,
      'releaseId': ?releaseId,
    };
    if (body.isEmpty) {
      throw ArgumentError.value(
        body,
        'fields',
        'at least one field must be supplied — the server rejects an empty '
            'patch with a 400',
      );
    }

    const action = 'Collection update';
    const failures = _CollectionFailures(_NotFoundMeaning.missingRow);
    final response = await sendForJson(
      () =>
          _dio.patch<String>('$_basePath/$id', options: _plainBody, data: body),
      action: action,
      family: failures,
    );
    return _singleEntry(
      response,
      action: action,
      family: failures,
      map: _mapEntry,
    );
  }

  @override
  Future<GameCollection> removeEntry(String id, {String? reason}) async {
    _checkEntryId(id);

    const action = 'Collection remove';
    // The one place a 404 is not a failure.
    const failures = _CollectionFailures(_NotFoundMeaning.alreadyRemoved);
    final response = await sendForJson(
      () => _dio.delete<String>(
        '$_basePath/$id',
        options: _plainBody,
        queryParameters: {'reason': ?reason},
      ),
      action: action,
      family: failures,
    );
    return _singleEntry(
      response,
      action: action,
      family: failures,
      map: _mapEntry,
    );
  }

  // ── Reading the answer ──────────────────────────────────────────────

  /// Unwraps the `{ collection }` envelope every single-entry endpoint returns
  /// (the mutating ones wrap it alongside a localized `message`, which the
  /// client does not consume), mapping it with [map].
  T _singleEntry<T>(
    RemoteJson response, {
    required String action,
    required _CollectionFailures family,
    required T Function(Map<String, dynamic> json) map,
  }) {
    final entry = response.body['collection'];
    if (entry is! Map<String, dynamic>) {
      throw GameCollectionRemotePermanentException(
        '$action response missing a "collection" object',
        statusCode: response.status,
      );
    }
    return parseRemote(
      family,
      () => map(entry),
      action: action,
      status: response.status,
    );
  }

  /// Maps a read's row to the entry plus the summary it embeds (#259).
  ///
  /// The summary is required here: a read's caller stores the entry, which it
  /// cannot do without the platform game and game the summary names. A row
  /// without it throws, and `parseRemote` files that as permanent.
  GameCollectionWithSummary _mapEntryWithSummary(Map<String, dynamic> json) =>
      (entry: _mapEntry(json), summary: _mapSummary(json));

  /// Maps the embedded `platformGame` object to a [PlatformGameSummary].
  ///
  /// The platform `slug` is not read: no table has a column for it. An empty
  /// image URL is none, as the columns can hold one: kept, it would stand in
  /// front of the artwork a list falls back to.
  static PlatformGameSummary _mapSummary(Map<String, dynamic> json) {
    final platformGame = json['platformGame'] as Map<String, dynamic>;
    final platform = platformGame['platform'] as Map<String, dynamic>;
    final game = platformGame['game'] as Map<String, dynamic>;
    return PlatformGameSummary(
      id: platformGame['id'] as String,
      platformId: platform['id'] as String,
      platformName: platform['name'] as String,
      image: _nonEmpty(platformGame['image']),
      thumbnail: _nonEmpty(platformGame['thumbnail']),
      game: GameSummary(
        id: game['id'] as String,
        title: game['title'] as String,
        subtitle: game['subtitle'] as String?,
        image: _nonEmpty(game['image']),
        thumbnail: _nonEmpty(game['thumbnail']),
        contentType: game['contentType'] is String
            ? ContentType.fromWire(game['contentType'] as String)
            : null,
        baseGames: mapExpansionLinks(game['baseGames']),
      ),
    );
  }

  static String? _nonEmpty(Object? wire) =>
      wire is String && wire.isNotEmpty ? wire : null;

  /// Maps a server collection payload to the domain [GameCollection].
  ///
  /// Explicit field mapping (not [GameCollection.fromJson]) keeps the server
  /// representation decoupled from the local-persistence representation: the
  /// response carries fields the model doesn't (`visibility`, `deleteReason`,
  /// the `release` summary — #253, #264, #404 — and the `platformGame`
  /// summary, which [_mapSummary] reads for the two reads) and omits the
  /// client-only sync flags, which default to `false` for this
  /// server-confirmed row.
  GameCollection _mapEntry(Map<String, dynamic> json) => GameCollection(
    id: json['id'] as String,
    userId: json['userId'] as String,
    platformGameId: json['platformGameId'] as String,
    medium: GameMedium.fromWire(json['medium'] as String),
    releaseId: json['releaseId'] as String?,
    quantity: json['quantity'] as int,
    rating: json['rating'] as int?,
    playCount: json['playCount'] as int?,
    playAgain: json['playAgain'] as bool?,
    favorite: json['favorite'] as bool?,
    comment: json['comment'] as String?,
    lastPlayed: _dateOrNull(json['lastPlayed']),
    lastUpdated: _dateOrNull(json['lastUpdated']),
    deletedAt: _dateOrNull(json['deletedAt']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  static DateTime? _dateOrNull(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  // ── Guards: requests the server is guaranteed to reject ─────────────

  /// `page` is 1-based, `limit` is capped at
  /// [GameCollectionRemoteDataSource.maxPageSize], and `(page - 1) * limit`
  /// may not exceed [GameCollectionRemoteDataSource.maxPageDepth]. The server
  /// **rejects** each violation with a 400 rather than clamping it. A 400
  /// mid-hydrate classifies as permanent, so an out-of-range page would fail
  /// the whole sync for a reason the caller could have known locally.
  void _checkPaging({required int page, required int limit}) {
    const maxPageSize = GameCollectionRemoteDataSource.maxPageSize;
    const maxPageDepth = GameCollectionRemoteDataSource.maxPageDepth;
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $maxPageSize (the server rejects a larger '
            'page rather than clamping it)',
      );
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'is 1-based');
    }
    // Divided rather than multiplied: `(page - 1) * limit` wraps on the VM for
    // a large enough page and would land back under the ceiling. For integers,
    // `x * limit > depth` holds exactly when `x > depth ~/ limit`, and `limit`
    // is at least 1 by now.
    if (page - 1 > maxPageDepth ~/ limit) {
      throw ArgumentError.value(
        page,
        'page',
        '(page - 1) * limit must not exceed $maxPageDepth',
      );
    }
  }

  /// The server validates `quantity` as positive. Zero is not "remove" — the
  /// repository contract says the same thing about its own add path.
  void _checkQuantity(int? quantity) {
    if (quantity != null && quantity < 1) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'must be greater than zero — use removeEntry to delete an entry',
      );
    }
  }

  /// One path segment of URL-safe characters: an entry id that can only
  /// reach the route it names. Every id the server mints is a cuid2, which
  /// this accepts.
  static final RegExp _wellFormedId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// The id goes into the path as it stands, so one that could leave the
  /// entry route is refused before the request; see the argument section on
  /// [GameCollectionRemoteDataSource] (#121).
  void _checkEntryId(String id) {
    if (!_wellFormedId.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'is not a well-formed entry id, so the request could reach another '
            'route',
      );
    }
  }
}

/// How the collection source builds its failures for the shared classifier.
///
/// [notFound] is what a 404 means for the request being made; see
/// [_NotFoundMeaning].
///
/// A 403 has no per-request reading, which is why only the 404 needs a
/// meaning: the API refuses an entry the actor may not see with a 404, not a
/// 403 (#365). The shared rule that a 403 without the envelope is a proxy or
/// WAF block rests on every 403 reaching these routes carrying a message, so
/// that Nest renders the envelope. There are two producers: the policy guard
/// on the controller, and the actor middleware applied to every route ahead
/// of it, which refuses an impersonated session with a raw literal rather
/// than a translation key. Both carry a message. A messageless 403 added to
/// either would be read as a proxy block and retried (#263), so those two are
/// where to look.
final class _CollectionFailures
    extends RemoteFailureFamily<GameCollectionRemoteException> {
  const _CollectionFailures(this.notFound)
    : super(
        transient: GameCollectionRemoteTransientException.new,
        permanent: GameCollectionRemotePermanentException.new,
      );

  final _NotFoundMeaning notFound;

  /// Reads an enveloped 404 as a statement about a row, which is only
  /// available when the application answered. A gateway or proxy answers 404
  /// too, and the shared rules already keep that transient, so every 404 this
  /// hook sees carries the envelope.
  ///
  /// This matters most for a removal: [_NotFoundMeaning.alreadyRemoved] tells
  /// the drain to mark the operation completed, and doing that for a request
  /// the service never saw would silently discard the user's deletion (the
  /// entry then reappears on the next hydrate). A patch has the same shape one
  /// step removed: [_NotFoundMeaning.missingRow] is permanent, so a proxy 404
  /// would park the user's edit (#121).
  ///
  /// [_NotFoundMeaning.unreachableEndpoint] claims nothing, so the shared 404
  /// default makes it transient: a collection list is never absent, so even
  /// an application 404 there means the route is not registered, a deployment
  /// fault rather than data. Every other refusal takes the shared default.
  @override
  GameCollectionRemoteException? refused(RemoteRefusal refusal) {
    if (refusal.status != 404) return null;
    return switch (notFound) {
      _NotFoundMeaning.alreadyRemoved => GameCollectionAlreadyRemovedException(
        refusal.message,
        statusCode: refusal.status,
        cause: refusal.cause,
      ),
      _NotFoundMeaning.missingRow => GameCollectionNotFoundException(
        refusal.message,
        statusCode: refusal.status,
        cause: refusal.cause,
      ),
      _NotFoundMeaning.unreachableEndpoint => null,
    };
  }
}
