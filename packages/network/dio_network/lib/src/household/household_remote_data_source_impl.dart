import 'package:dio/dio.dart';
import 'package:http_status/http_status.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/decode_json_body.dart';
import '../network/user_projection.dart';

/// [HouseholdRemoteDataSource] over a **per-server** Dio instance (#39).
///
/// The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included). The BetterAuth session the endpoint
/// requires is attached below this class: by the per-server auth plumbing
/// (TokenInterceptor) on native, and by the browser, as its session cookie,
/// on web. This class adds no auth handling of its own; it is constructed
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
  /// (401), a request timeout (408), the throttle (429), and proxy
  /// authentication (407).
  ///
  /// 407 is here because the household API has no code path that emits it —
  /// it is defined to come from a proxy, so it says the request never reached
  /// the application (#350). 511 belongs to the same family and needs no entry:
  /// it is a 5xx, so `status >= 500` already covers it.
  static const Set<int> _retryable4xx = {401, 407, 408, 429};

  /// Pinned on every request rather than inherited from the injected Dio.
  ///
  /// Asking for `Response<String>` is not sufficient on its own: `fetch`'s
  /// forcing block is skipped when the instance's `responseType` is already
  /// `bytes`/`stream` (`dio_mixin.dart:419-421`), and `assureResponse` then
  /// casts the body to `String` anyway (`:807`). That `TypeError` escapes as
  /// `DioException(type: unknown)` with no response attached — the same
  /// status-losing failure #265 fixed here, arriving by a different route.
  /// #360 finished generalising this: every `_dio` call site under
  /// `packages/network/*/lib` now pins `responseType` per request.
  ///
  /// A fresh instance per call: `Options` is mutable, and one shared between
  /// the two request methods is a shared mutable default waiting to be edited.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

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
        options: _plainBody,
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
      throw _classifyStatus(
        status,
        '$action returned $status',
        cause: null,
        body: response.data,
      );
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
    required String clientRequestId,
    String? description,
    String? image,
    String? language,
    String? visibility,
  }) async {
    _checkClientRequestId(clientRequestId);
    return _sendForHousehold(
      () => _dio.post<String>(
        '/api/households',
        options: _plainBody,
        data: {
          'name': name,
          'clientRequestId': clientRequestId,
          'description': ?description,
          'image': ?image,
          'language': ?language,
          'visibility': ?visibility,
        },
      ),
      action: 'Household create',
    );
  }

  @override
  Future<Household> updateHousehold(
    String householdId,
    HouseholdUpdate update,
  ) async {
    if (householdId.isEmpty) {
      throw ArgumentError.value(householdId, 'householdId', 'is empty');
    }
    if (update.isEmpty) {
      throw ArgumentError.value(
        update,
        'update',
        'changes nothing (the server rejects an empty patch with a 400)',
      );
    }

    return _sendForHousehold(
      () => _dio.patch<String>(
        '$_basePath/${Uri.encodeComponent(householdId)}',
        options: _plainBody,
        data: {
          'name': ?update.name,
          // A null description is how the server is told to clear it, so
          // the key is sent rather than dropped (#476).
          if (update.clearDescription)
            'description': null
          else
            'description': ?update.description,
          if (update.memberInvitePolicy case final policy?)
            'settings': {'memberInvitePolicy': policy.toWire()},
        },
      ),
      action: 'Household update',
      // The route names the household, so an enveloped 404 is about it.
      rowRoute: true,
    );
  }

  /// Sends [request] and reads the `{ message, household }` answer the
  /// create and the update share. [rowRoute] is passed to [_classifyStatus].
  Future<Household> _sendForHousehold(
    Future<Response<String>> Function() request, {
    required String action,
    bool rowRoute = false,
  }) async {
    late final Response<String> response;
    try {
      response = await request();
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action, rowRoute: rowRoute);
    } on Object catch (error) {
      throw HouseholdRemoteTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw HouseholdRemoteTransientException('$action returned no status');
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(
        status,
        '$action returned $status',
        cause: null,
        body: response.data,
        rowRoute: rowRoute,
      );
    }

    final data = await _requireJsonObject(
      response.data,
      action: action,
      status: status,
    );

    final household = data['household'];
    if (household is! Map<String, dynamic>) {
      throw HouseholdRemotePermanentException(
        '$action response missing a "household" object',
        statusCode: status,
      );
    }

    try {
      return _mapHousehold(household);
    } on Object catch (error) {
      throw HouseholdRemotePermanentException(
        'Failed to parse the $action response: $error',
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
    settings: _mapSettings(json['settings']),
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
  ///
  /// The `user` field is unwrapped too: the list embeds the member's account
  /// as `user: { id, username, profile: { avatarUrl, displayName } }`, the
  /// projection the event roster embeds, and [readUserProjection] reads it
  /// for both (#304). An absent or null `user` leaves the member nameless
  /// rather than failing the page, and one of the wrong shape throws.
  HouseholdMember _mapMember(Map<String, dynamic> json) {
    final user = readUserProjection(json['user'], row: 'member');
    return HouseholdMember(
      id: json['id'] as String,
      userId: json['userId'] as String,
      householdId: json['householdId'] as String,
      // Read strictly, not `?? true`: this is a non-nullable server column,
      // and defaulting a *sharing* flag to its permissive value on a payload
      // we could not read is the wrong direction to fail in.
      showAllGames: json['showAllGames'] as bool,
      role: _mapRole(json['role']),
      username: user.username,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  /// Reads the household's settings: the list, the detail and the update
  /// answer carry them, and the create answer does not (#476).
  ///
  /// An absent or null `settings` is none, which leaves a cached policy as
  /// it is. One of the wrong shape, or a policy that is not a string, is a
  /// contract breach and throws, for the same reason the role projection
  /// does: [MemberInvitePolicy.unknown] is for a policy name this client
  /// does not know, not for a payload it failed to read.
  static HouseholdSettings? _mapSettings(Object? settings) {
    if (settings == null) return null;
    if (settings is! Map<String, dynamic>) {
      throw FormatException(
        'household "settings" is ${settings.runtimeType}, expected an object',
      );
    }
    final policy = settings['memberInvitePolicy'];
    if (policy is! String) {
      throw FormatException(
        'household settings "memberInvitePolicy" is ${policy.runtimeType}, '
        'expected a string',
      );
    }
    return HouseholdSettings(
      memberInvitePolicy: MemberInvitePolicy.fromWire(policy),
    );
  }

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

  /// The server trims `clientRequestId`, then requires 1 to
  /// [HouseholdRemoteDataSource.maxClientRequestIdLength] characters, and
  /// answers a violation with a 400. That is permanent, and a permanent
  /// create is parked on its first attempt (#121), so a key the caller got
  /// wrong is refused here instead, with an error outside the
  /// transient/permanent split: the sender counts it as a client fault
  /// rather than parking it as the server's verdict.
  ///
  /// This matches the server exactly for ASCII keys, and every key this
  /// client mints is a cuid2, which is ASCII. Past ASCII the two can
  /// disagree at the edges: Dart's `trim` also strips U+0085, which the
  /// server's does not, and the server counts a surrogate pair as one
  /// character where `length` counts two.
  ///
  /// The key is still sent untrimmed: the server trims it before storing or
  /// matching it, so the two forms are one key.
  void _checkClientRequestId(String clientRequestId) {
    const maxLength = HouseholdRemoteDataSource.maxClientRequestIdLength;
    final length = clientRequestId.trim().length;
    if (length == 0 || length > maxLength) {
      throw ArgumentError.value(
        clientRequestId,
        'clientRequestId',
        'must be 1 to $maxLength characters after trimming (the server '
            'rejects anything else with a 400)',
      );
    }
  }

  /// Decodes a response body the transport was told not to touch, and
  /// requires it to be a JSON object.
  ///
  /// Both request methods ask Dio for `Response<String>` and pin
  /// `responseType` per call (see `_plainBody` above) — together, not either
  /// alone. `DioMixin.fetch` forces `responseType` from `T` — `String` gives
  /// `plain`, and **anything else, `Object?` included, gives `json`**
  /// (`dio_mixin.dart:417-427`).
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
      // **transient**. Permanent says a retry cannot succeed, and a caller that
      // believes it gives up over a fault the server had no part in, which is
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
  /// [rowRoute] is passed to [_classifyStatus].
  HouseholdRemoteException _classifyDioException(
    DioException error, {
    required String action,
    bool rowRoute = false,
  }) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        '$action failed with status $status',
        cause: error,
        body: error.response?.data,
        rowRoute: rowRoute,
      );
    }
    return HouseholdRemoteTransientException('$action failed', cause: error);
  }

  /// Classifies an answered request by what its status licenses a caller to
  /// conclude.
  ///
  /// The question is never "did this fail" — the status already says so — but
  /// **"will the same request fail the same way again?"**, because that is
  /// what the drain acts on. Permanent parks the queue entry, so it stops
  /// retrying until someone retries or discards it by hand (#121); transient
  /// keeps it queued. So the bar for permanent is evidence that the household
  /// API itself rejected the request, not merely that something rejected
  /// it.
  ///
  /// - **5xx, and 401 / 407 / 408 / 429** — transient. Expired session,
  ///   timeout, throttle, proxy auth: all conditions a later attempt can
  ///   survive.
  /// - **404** — transient, unless [rowRoute] is set and the body
  ///   carries the API's error envelope, which is
  ///   [HouseholdNotFoundException]. The list and the create are fixed
  ///   routes, so a 404 from either can only mean the request did not reach
  ///   the module (#297). The update names a household, and its enveloped
  ///   404 says that household is gone (#476). See the branch below.
  /// - **403** — transient unless the body carries the API's error envelope.
  ///   The application can genuinely emit a 403, so this one is gated on
  ///   evidence rather than settled by the status (#350).
  /// - **409 saying `retryable: true`** — transient. It is the backend's
  ///   answer to a deadlock that outlived its own retry: a concurrency
  ///   accident on the server, not a judgement on the request (#431).
  /// - **Any other 4xx** — permanent. A 400, any other 409, or a 422 on these
  ///   routes is the application rejecting the request's content, and the
  ///   content will not change on retry.
  /// - **1xx / 3xx** — transient. Surfaced only by the permissive
  ///   `validateStatus`, and carrying no rejection semantics at all.
  ///
  /// [body] is the raw, undecoded body when there is one. Only the 403, 409
  /// and row-level 404 branches read it, and only through the bounded
  /// probes in `api_error_envelope.dart`.
  ///
  /// [rowRoute] says the route names a household by id, so an enveloped
  /// 404 from it is about that household. Only the update sets it.
  HouseholdRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
    required Object? body,
    bool rowRoute = false,
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
      // On a route that names the household, an enveloped 404 says it is
      // gone (#476). The envelope is the minimum bar, and why it is accepted
      // though Nest's route-not-found carries it too is in the contract.
      if (rowRoute && isApiErrorEnvelope(body, status)) {
        return HouseholdNotFoundException(
          '$message — the household is gone',
          cause: cause,
          statusCode: status,
        );
      }
      // The list and the create are fixed routes, so a 404 from either says
      // the request did not reach the household module: a misrouted path
      // prefix, an API not deployed yet, a proxy or gateway answering for
      // it. Permanent would end a hydrate for the life of the process, and
      // on the create path it is worse than that: permanent parks the queued
      // create (#121), stranding the user's household until someone retries
      // it by hand, for a failure a retry thirty seconds later would have
      // survived (#297).
      //
      // The envelope is deliberately NOT consulted for those routes. It does
      // not separate the two cases on a *fixed* route, because Nest answers
      // an unmatched route with the same envelope (`Cannot POST
      // /api/households`, rendered by the global `I18nExceptionFilter`) —
      // the residual the collection source documents on its own
      // `_isApplicationError`. So an envelope-gated rule would still
      // classify a partial deploy as a rejection, which is the exact bug
      // #297 is about. A 404 without the envelope from the update lands
      // here too: nothing says the application wrote it.
      return HouseholdRemoteTransientException(
        '$message — the household route was not reachable',
        cause: cause,
        statusCode: status,
      );
    }
    if (status == HttpStatusCode.forbidden &&
        !isApiErrorEnvelope(body, status)) {
      // Unlike 404, the envelope IS a usable discriminator at 403. Nest
      // answers an unmatched route with a 404 carrying the standard envelope
      // — which is why #297 could not gate the 404 on it — but it does not
      // answer an unmatched route with a 403. So a 403 without the
      // envelope was not written by the application: a corporate proxy or WAF
      // blocked the POST.
      //
      // The cost of getting this wrong runs one way. Permanent does not merely
      // fail the attempt: it parks the queued create (#121), so the household
      // the user just created waits for someone to retry it by hand, over a
      // block that a retry after they leave the network would have survived. A
      // genuine authorization refusal misread as transient is only retried, at
      // most once a drain pass (#350).
      //
      // What this rests on: every production 403 on these routes is raised
      // with a message, so Nest renders the envelope. A bare
      // `ForbiddenException()` added to a household route later would carry
      // none, read here as a proxy block, and retry a refusal that will never
      // change. Nothing in this package can notice that happen — #263 is the
      // mechanism that would.
      return HouseholdRemoteTransientException(
        '$message — the request did not reach the household module',
        cause: cause,
        statusCode: status,
      );
    }
    if (status == HttpStatusCode.conflict && isRetryableRefusal(body)) {
      // A deadlock that outlived the server's own retry (#431). The backend
      // answers 409 because the cure is the caller's, and says
      // `retryable: true` because the request itself was fine: the same
      // create is expected to succeed. Read the field, not the message,
      // which is translated.
      return HouseholdRemoteTransientException(
        '$message — the server hit a deadlock and asked for a retry',
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
