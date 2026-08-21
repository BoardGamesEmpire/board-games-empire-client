import 'package:dio/dio.dart';
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
/// deployments included), and the existing per-server auth plumbing
/// (TokenInterceptor) attaches the BetterAuth session the endpoints require.
/// This class adds no auth handling of its own; it is constructed from the
/// per-server container by the network installer, so like
/// [HouseholdRemoteDataSourceImpl] it does **not** build or own its Dio and is
/// intentionally not an injectable global singleton.
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

  /// 4xx statuses that are nonetheless worth retrying: an expired session
  /// (401), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 408, 429};

  @override
  Future<List<GameCollection>> fetchCollectionPage({
    int offset = 0,
    int limit = GameCollectionRemoteDataSource.maxPageSize,
    bool includeDeleted = false,
    bool deletedOnly = false,
    GameMedium? medium,
    bool? favorite,
    DateTime? updatedSince,
  }) async {
    _checkPaging(offset: offset, limit: limit);

    const action = 'Collection list';
    final response = await _send(
      request: () => _dio.get<Object?>(
        _basePath,
        queryParameters: {
          'offset': offset,
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
      // A list route that 404s was never reached — see _NotFoundMeaning.
      notFound: _NotFoundMeaning.unreachableEndpoint,
    );

    final collections = response.body['collections'];
    if (collections is! List) {
      throw GameCollectionRemotePermanentException(
        '$action response missing a "collections" array',
        statusCode: response.status,
      );
    }

    return _parse(
      () => collections
          .map((entry) => _mapEntry(entry as Map<String, dynamic>))
          .toList(growable: false),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<GameCollection> fetchEntry(String id) async {
    const action = 'Collection fetch';
    final response = await _send(
      request: () =>
          _dio.get<Object?>('$_basePath/$id', queryParameters: const {}),
      action: action,
      notFound: _NotFoundMeaning.missingRow,
    );
    return _singleEntry(response, action: action);
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
    final response = await _send(
      request: () => _dio.post<Object?>(
        _basePath,
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
      notFound: _NotFoundMeaning.missingRow,
    );
    return _singleEntry(response, action: action);
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
    final response = await _send(
      request: () => _dio.patch<Object?>('$_basePath/$id', data: body),
      action: action,
      notFound: _NotFoundMeaning.missingRow,
    );
    return _singleEntry(response, action: action);
  }

  @override
  Future<GameCollection> removeEntry(String id, {String? reason}) async {
    const action = 'Collection remove';
    final response = await _send(
      request: () => _dio.delete<Object?>(
        '$_basePath/$id',
        queryParameters: {'reason': ?reason},
      ),
      action: action,
      // The one place a 404 is not a failure.
      notFound: _NotFoundMeaning.alreadyRemoved,
    );
    return _singleEntry(response, action: action);
  }

  // ── Request plumbing ────────────────────────────────────────────────

  /// Sends [request] and returns its decoded body, having converted every
  /// failure mode into a [GameCollectionRemoteException].
  Future<({Map<String, dynamic> body, int status})> _send({
    required Future<Response<Object?>> Function() request,
    required String action,
    required _NotFoundMeaning notFound,
  }) async {
    late final Response<Object?> response;
    try {
      response = await request();
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action, notFound: notFound);
    } on Object catch (error) {
      // Contract breach territory (nothing else should escape Dio); stay
      // conservative and transient so the caller can retry.
      //
      // `Object` and not `Exception`, deliberately: the interface promises
      // callers never see a raw transport error, and an `Error` escaping here
      // unwrapped would break that in the drain rather than in a test. The one
      // `Error` this used to swallow — Dio's own body cast — no longer reaches
      // here at all, because the request now asks for an untyped body. Mapping
      // errors are classified separately, and permanently, by `_parse`.
      throw GameCollectionRemoteTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw GameCollectionRemoteTransientException(
        '$action returned no status',
      );
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(
        status,
        '$action returned $status',
        cause: null,
        notFound: notFound,
        body: response.data,
      );
    }

    // Typed as `Object?` deliberately. Asking Dio for
    // `Response<Map<String, dynamic>>` makes it cast the decoded body itself
    // (`data as T?`, dio_mixin.dart:741) on the success path, before this
    // method sees anything. A 2xx whose body is not a JSON object — an HTML
    // captive-portal page, a bare array — would throw a `TypeError` from
    // inside `request()`, reach the `on Object` branch above, and be reported
    // as a **transient** failure that retries forever. The interface promises
    // that case is permanent, so the type check belongs here, after the status
    // is known.
    final body = response.data;
    if (body is! Map<String, dynamic>) {
      throw GameCollectionRemotePermanentException(
        body == null
            ? '$action returned an empty body'
            : '$action returned a body that is not a JSON object',
        statusCode: status,
      );
    }
    return (body: body, status: status);
  }

  /// Unwraps the `{ collection }` envelope every single-entry endpoint returns
  /// (the mutating ones wrap it alongside a localized `message`, which the
  /// client does not consume).
  GameCollection _singleEntry(
    ({Map<String, dynamic> body, int status}) response, {
    required String action,
  }) {
    final entry = response.body['collection'];
    if (entry is! Map<String, dynamic>) {
      throw GameCollectionRemotePermanentException(
        '$action response missing a "collection" object',
        statusCode: response.status,
      );
    }
    return _parse(
      () => _mapEntry(entry),
      action: action,
      status: response.status,
    );
  }

  /// A 2xx whose body cannot be mapped is a permanent failure: retrying the
  /// same request produces the same unparseable payload.
  T _parse<T>(T Function() map, {required String action, required int status}) {
    try {
      return map();
    } on Object catch (error) {
      throw GameCollectionRemotePermanentException(
        'Failed to parse the $action response: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  /// Maps a server collection payload to the domain [GameCollection].
  ///
  /// Explicit field mapping (not [GameCollection.fromJson]) keeps the server
  /// representation decoupled from the local-persistence representation: the
  /// response carries fields the model doesn't (`visibility`, `deleteReason`,
  /// and the embedded `platformGame` / `release` summary — #253 D5, #259) and
  /// omits the client-only sync flags, which default to `false` for this
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

  /// `limit` is capped at [GameCollectionRemoteDataSource.maxPageSize] and
  /// `offset` at [GameCollectionRemoteDataSource.maxOffset], both **rejected
  /// with a 400 rather than clamped**. A 400 mid-hydrate classifies as
  /// permanent, so an out-of-range page would fail the whole sync for a reason
  /// the caller could have known locally.
  void _checkPaging({required int offset, required int limit}) {
    const maxPageSize = GameCollectionRemoteDataSource.maxPageSize;
    const maxOffset = GameCollectionRemoteDataSource.maxOffset;
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $maxPageSize (the server rejects a larger '
            'page rather than clamping it)',
      );
    }
    if (offset < 0 || offset > maxOffset) {
      throw ArgumentError.value(
        offset,
        'offset',
        'must be between 0 and $maxOffset',
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

  // ── Failure classification ──────────────────────────────────────────

  /// A response status, when present, is authoritative; without one the
  /// failure is a connection-level fault and always transient.
  /// Whether [body] is the API's own error envelope for a response carrying
  /// [status] — the evidence that the application answered rather than
  /// something in front of it.
  ///
  /// Every application `HttpException` is rendered by the backend's global
  /// `I18nExceptionFilter` as `{ statusCode, message, error }`
  /// (`libs/common/i18n/src/lib/i18n-exception.filter.ts`), and
  /// `translateException` builds that body from the exception's own status —
  /// `{ statusCode: status, message, error: STATUS_CODES[status] }`
  /// (`libs/common/i18n/src/lib/translate-exception.ts`). All three fields are
  /// therefore always present, and `statusCode` always agrees with the HTTP
  /// status. So the whole shape is required, not a prefix of it: a body
  /// missing the `error` label, or announcing a status other than the one it
  /// arrived with, was written by some other producer — a gateway rewriting an
  /// upstream failure, most likely. A proxy answering 404 sends HTML, nothing,
  /// or its own unrelated JSON, and none of those clear this bar, which is
  /// what separates "the service says this row is gone" from "the request
  /// never got there".
  ///
  /// **Known residual:** if the collection module itself is not deployed, Nest
  /// answers with its own route-not-found — which *is* this envelope, carrying
  /// `Cannot DELETE /api/game-collections/…`. Distinguishing that from the
  /// service's own 404 would mean matching message text, which is translated
  /// per request locale and so not something to depend on. The mitigating
  /// property is that the list route 404s in the same deployment, and that is
  /// transient unconditionally, so a missing module surfaces as a hydrate that
  /// never succeeds.
  static bool _isApplicationError(Object? body, int status) =>
      body is Map &&
      body['statusCode'] == status &&
      body['message'] != null &&
      body['error'] is String;

  GameCollectionRemoteException _classifyDioException(
    DioException error, {
    required String action,
    required _NotFoundMeaning notFound,
  }) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        '$action failed with status $status',
        cause: error,
        notFound: notFound,
        body: error.response?.data,
      );
    }
    return GameCollectionRemoteTransientException(
      '$action failed',
      cause: error,
    );
  }

  GameCollectionRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
    required _NotFoundMeaning notFound,
    required Object? body,
  }) {
    final transient = status >= 500 || _retryable4xx.contains(status);
    if (transient) {
      return GameCollectionRemoteTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status == 404) {
      // Both row-level readings of a 404 below are conclusions about a ROW,
      // and neither is available unless the application actually answered.
      // A gateway, proxy or load balancer answers 404 too, and then the
      // status says only that the request did not arrive — so retry.
      //
      // This matters most for a removal: `alreadyRemoved` tells the drain to
      // mark the operation completed, and doing that for a request the
      // service never saw silently discards the user's deletion (the entry
      // then reappears on the next hydrate). A patch has the same shape one
      // step removed: `missingRow` is permanent, so a proxy 404 would discard
      // the user's edit.
      if (!_isApplicationError(body, status)) {
        return GameCollectionRemoteTransientException(
          '$message — the route was not reachable',
          cause: cause,
          statusCode: status,
        );
      }
      return switch (notFound) {
        _NotFoundMeaning.alreadyRemoved =>
          GameCollectionAlreadyRemovedException(
            message,
            cause: cause,
            statusCode: status,
          ),
        _NotFoundMeaning.missingRow => GameCollectionNotFoundException(
          message,
          cause: cause,
          statusCode: status,
        ),
        // A collection list is never absent, so even an application 404 here
        // means the route is not registered — a deployment fault, not data.
        _NotFoundMeaning.unreachableEndpoint =>
          GameCollectionRemoteTransientException(
            '$message — the collection route was not reachable',
            cause: cause,
            statusCode: status,
          ),
      };
    }
    if (status >= 400) {
      return GameCollectionRemotePermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A non-2xx, non-4xx/5xx status (1xx/3xx surfaced by a permissive
    // validateStatus) carries no rejection semantics — transient.
    return GameCollectionRemoteTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
