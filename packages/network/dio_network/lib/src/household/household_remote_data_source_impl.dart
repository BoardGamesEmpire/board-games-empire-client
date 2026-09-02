import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/decode_json_body.dart';

/// [HouseholdRemoteDataSource] over a **per-server** Dio instance (#39).
///
/// The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included), and the existing per-server auth
/// plumbing (TokenInterceptor) attaches the BetterAuth session the endpoint
/// requires. This class adds no auth handling of its own; it is constructed
/// from the per-server container by the network installer (#39 wiring), so
/// unlike [WellKnownClientImpl] it does **not** build or own its Dio, and it
/// is intentionally **not** an injectable global singleton (the per-server
/// Dio is outside the global graph).
///
/// Failure taxonomy per the [HouseholdRemoteDataSource] contract — see that
/// interface for the transient/permanent split.
class HouseholdRemoteDataSourceImpl implements HouseholdRemoteDataSource {
  const HouseholdRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _basePath = '/api/households';

  /// 4xx statuses that are nonetheless worth retrying: an expired session
  /// (401), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 408, 429};

  @override
  Future<PaginatedResult<HouseholdWithMembers>> fetchHouseholds({
    int page = 1,
    int limit = HouseholdRemoteDataSource.maxPageSize,
  }) async {
    _checkPaging(page: page, limit: limit);

    const action = 'Household list';
    late final Response<String> response;
    try {
      response = await _dio.get<String>(
        _basePath,
        queryParameters: {'page': page, 'limit': limit},
      );
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action);
    } on Object catch (error) {
      throw HouseholdRemoteTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw const HouseholdRemoteTransientException(
        'Household list returned no status',
      );
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(status, '$action returned $status', cause: null);
    }

    final body = await _requireJsonObject(
      response.data,
      action: action,
      status: status,
    );

    try {
      return PaginatedResult.fromEnvelope(
        body,
        key: 'households',
        item: _mapHouseholdWithMembers,
      );
    } on Object catch (error) {
      throw HouseholdRemotePermanentException(
        'Failed to parse the $action response: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  @override
  Future<Household> createHousehold({
    required String name,
    String? description,
    String? image,
    String? language,
    String? visibility,
  }) async {
    const action = 'Household create';
    late final Response<String> response;
    try {
      response = await _dio.post<String>(
        '/api/households',
        data: {
          'name': name,
          'description': ?description,
          'image': ?image,
          'language': ?language,
          'visibility': ?visibility,
        },
      );
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action);
    } on Object catch (error) {
      throw HouseholdRemoteTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw const HouseholdRemoteTransientException(
        'Household create returned no status',
      );
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(status, '$action returned $status', cause: null);
    }

    final data = await _requireJsonObject(
      response.data,
      action: action,
      status: status,
    );

    final household = data['household'];
    if (household is! Map<String, dynamic>) {
      throw HouseholdRemotePermanentException(
        'Household create response missing a "household" object',
        statusCode: status,
      );
    }

    try {
      return _mapHousehold(household);
    } on Object catch (error) {
      throw HouseholdRemotePermanentException(
        'Failed to parse created household: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  /// Maps the server household payload to the domain [Household].
  ///
  /// Explicit field mapping (not [Household.fromJson]) keeps the server
  /// representation decoupled from the local-persistence representation:
  /// the server response carries fields the model doesn't (languageTagId,
  /// createdById, visibility, embedded members …) and omits the client-only
  /// sync flags, which default to `false` for this server-confirmed row.
  Household _mapHousehold(Map<String, dynamic> json) => Household(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    image: json['image'] as String?,
    deletedAt: _dateOrNull(json['deletedAt']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  /// Maps one row of the list endpoint — a household plus the members the
  /// include embeds.
  /// An absent `members` key is an empty roster — a response that did not
  /// carry the include. A `members` of the wrong type is a contract breach and
  /// throws, for the same reason the role projection does: silently reporting
  /// "no members" for a payload we failed to read would look exactly like a
  /// household the user is alone in.
  HouseholdWithMembers _mapHouseholdWithMembers(Map<String, dynamic> json) {
    final members = json['members'];
    if (members != null && members is! List) {
      throw FormatException(
        'household "members" is ${members.runtimeType}, expected a list',
      );
    }
    return (
      household: _mapHousehold(json),
      members: members == null
          ? const <HouseholdMember>[]
          : (members as List)
                .map((member) => _mapMember(member as Map<String, dynamic>))
                .toList(growable: false),
    );
  }

  /// Maps a server member payload to the domain [HouseholdMember].
  ///
  /// The `role` field needs unwrapping, not just reading: the server embeds
  /// the join row with the role nested inside it —
  /// `role: { …join…, role: { id, name } }` — while the domain model carries
  /// a [HouseholdRole] resolved from the role **name**.
  ///
  /// Handing that object to `HouseholdMember.fromJson` would not fail. The
  /// generated decoder calls `$enumDecodeNullable(..., unknownValue:
  /// HouseholdRole.unknown)`, a Map matches no entry in the enum map, and
  /// every member would come back `unknown` — silently, with `isOwner` and
  /// `isAdmin` false for everyone. Unwrapping here keeps
  /// [HouseholdRole.unknown] meaning what it was designed to mean: a
  /// server-defined role name this client does not recognise.
  HouseholdMember _mapMember(Map<String, dynamic> json) => HouseholdMember(
    id: json['id'] as String,
    userId: json['userId'] as String,
    householdId: json['householdId'] as String,
    // Read strictly, not `?? true`: this is a non-nullable server column, and
    // defaulting a *sharing* flag to its permissive value on a payload we
    // could not read is the wrong direction to fail in.
    showAllGames: json['showAllGames'] as bool,
    role: _mapRole(json['role']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  /// Reads the role name out of the embedded join projection.
  ///
  /// A null projection is a member with no role binding, which the model
  /// represents as a null role. A projection whose shape is wrong is a
  /// contract breach and throws — it must not be laundered into
  /// [HouseholdRole.unknown], which would make a parsing failure
  /// indistinguishable from a custom server role.
  static HouseholdRole? _mapRole(Object? projection) {
    if (projection == null) return null;
    if (projection is! Map<String, dynamic>) {
      throw FormatException(
        'member "role" is ${projection.runtimeType}, expected the embedded '
        'role projection',
      );
    }
    final role = projection['role'];
    if (role is! Map<String, dynamic>) {
      throw FormatException(
        'member "role" projection is missing its nested "role" object, got '
        '${role.runtimeType}',
      );
    }
    final name = role['name'];
    if (name is! String) {
      throw FormatException(
        'member role is missing a "name", got ${name.runtimeType}',
      );
    }
    return HouseholdRole.fromWire(name);
  }

  static DateTime? _dateOrNull(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  /// `page` is 1-based and `limit` is capped at
  /// [HouseholdRemoteDataSource.maxPageSize]; the server **rejects** a
  /// violation with a 400 rather than clamping it. A 400 mid-hydrate
  /// classifies as permanent, so an out-of-range page would fail the whole
  /// sync for a reason the caller could have known locally.
  void _checkPaging({required int page, required int limit}) {
    const maxPageSize = HouseholdRemoteDataSource.maxPageSize;
    const maxPageDepth = HouseholdRemoteDataSource.maxPageDepth;
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
    if ((page - 1) * limit > maxPageDepth) {
      throw ArgumentError.value(
        page,
        'page',
        '(page - 1) * limit must not exceed $maxPageDepth',
      );
    }
  }

  /// Decodes a response body the transport was told not to touch, and
  /// requires it to be a JSON object.
  ///
  /// Both request methods ask Dio for `Response<String>`, which is the only
  /// type argument that keeps Dio out of the body entirely: `DioMixin.fetch`
  /// forces `responseType` from `T` — `String` gives `plain`, and **anything
  /// else, `Object?` included, gives `json`** (`dio_mixin.dart:417-427`).
  ///
  /// That matters because either half of Dio's own handling loses the status.
  /// Asking for `Response<Map<String, dynamic>>` makes Dio cast the decoded
  /// body; asking for anything non-`String` makes it `jsonDecode` a body whose
  /// **content type** claims JSON. A cast failure or a `FormatException` both
  /// escape as `DioException(type: unknown)` with **no response attached**, so
  /// `_classifyDioException` sees a null status and returns transient — for a
  /// server that answered, and whatever it answered with.
  ///
  /// The per-server Dio sets `validateStatus: (_) => true` (`DioFactory`), so
  /// every status reached that path: an HTML 400 from a proxy retried forever,
  /// and a 404 was transient by accident rather than by the rule #297 wrote.
  /// Decoding here, after the status is known, restores both and makes a
  /// non-object 2xx permanent as the interface documents (#265, #182).
  ///
  /// Realistic triggers: a captive portal or SPA catch-all serving HTML — under
  /// `text/html` **or** `application/json`, since content type is not a promise
  /// about content — and a dropped connection truncating a genuine JSON body.
  Future<Map<String, dynamic>> _requireJsonObject(
    String? raw, {
    required String action,
    required int status,
  }) async {
    if (raw == null || raw.isEmpty) {
      throw HouseholdRemotePermanentException(
        '$action returned an empty body',
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = await decodeJsonBody(raw);
    } on FormatException catch (error) {
      throw HouseholdRemotePermanentException(
        '$action returned a body that is not JSON',
        statusCode: status,
        cause: error,
      );
    } on Object catch (error) {
      // Not a statement about the response. `decodeJsonBody` hands a large body
      // to another isolate, and a failure to spawn one is a local, momentary
      // condition — so this is the one decode failure that must stay
      // **transient**. Permanent would cancel the queued operation and discard
      // the user's household over a fault the server had no part in, which is
      // the shape #297 exists to prevent.
      //
      // This sits outside the `on Object` net around the Dio call above,
      // because decoding moved out from under it when the body became a
      // `String` — so without this clause the interface's "callers never see a
      // raw transport exception" would not hold, and `CreateHouseholdBloc`
      // catches `HouseholdRemoteException` with no fallback beneath it.
      throw HouseholdRemoteTransientException(
        '$action could not be decoded',
        statusCode: status,
        cause: error,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw HouseholdRemotePermanentException(
        '$action returned a body that is not a JSON object',
        statusCode: status,
      );
    }
    return decoded;
  }

  /// A response status, when present, is authoritative; without one the
  /// failure is a connection-level fault and always transient.
  HouseholdRemoteException _classifyDioException(
    DioException error, {
    required String action,
  }) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        '$action failed with status $status',
        cause: error,
      );
    }
    return HouseholdRemoteTransientException('$action failed', cause: error);
  }

  HouseholdRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
  }) {
    final transient = status >= 500 || _retryable4xx.contains(status);
    if (transient) {
      return HouseholdRemoteTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status == 404) {
      // EVERY household route is fixed server-side — there is no household
      // route whose 404 could mean "this row is gone" — so a 404 always says
      // the request did not reach the household module: a misrouted path
      // prefix, an API not deployed yet, a proxy or gateway answering for
      // it. Permanent would end a hydrate for the life of the process, and
      // on the create path it is worse than that: once #121 owns cancel
      // semantics, permanent cancels the queue entry and discards the
      // user's household for a failure a retry thirty seconds later would
      // have survived (#297).
      //
      // Note what is deliberately NOT consulted here: the API's own error
      // envelope. The collection data source requires that envelope before
      // reading a 404 as a statement about a row, because a proxy 404
      // cannot license such a conclusion. That check does not separate the
      // two cases on a *fixed* route, because Nest answers an unmatched
      // route with the same envelope (`Cannot POST /api/households`,
      // rendered by the global `I18nExceptionFilter`) — the residual the
      // collection source documents on its own `_isApplicationError`. So an
      // envelope-gated rule would still classify a partial deploy as a
      // rejection, which is the exact bug #297 is about. Since no household
      // route has a row-level reading to gate, the envelope buys nothing
      // and is left out rather than added as decoration.
      //
      // The membership mutations in #122 add the first household routes
      // whose 404 *can* carry row semantics — a member or household the
      // request names by id and the server reports gone. That is when this
      // grows a per-call-site meaning plus the envelope check, following the
      // collection source as the template — not before. (Not #272: that
      // epic is read-only and its list and detail screens both read the
      // local cache, so it adds no route with a row-level 404.)
      return HouseholdRemoteTransientException(
        '$message — the household route was not reachable',
        cause: cause,
        statusCode: status,
      );
    }
    if (status >= 400) {
      return HouseholdRemotePermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A non-2xx, non-4xx/5xx status (1xx/3xx surfaced by a permissive
    // validateStatus) carries no rejection semantics — transient.
    return HouseholdRemoteTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
