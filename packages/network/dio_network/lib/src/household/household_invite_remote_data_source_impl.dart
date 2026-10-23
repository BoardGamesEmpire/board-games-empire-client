import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/decode_json_body.dart';

/// [HouseholdInviteRemoteDataSource] over a **per-server** Dio instance
/// (#455).
///
/// Built on the DataGateway source's request plumbing (#41): the body is
/// asked for as a `String` with the response type pinned on every request,
/// decoded here after the status is read, and probed for the API's error
/// envelope with a bounded synchronous parse. It does not build or own its
/// Dio; the network installer constructs it from the per-server container.
///
/// Failure taxonomy per the [HouseholdInviteRemoteDataSource] contract.
class HouseholdInviteRemoteDataSourceImpl
    implements HouseholdInviteRemoteDataSource {
  const HouseholdInviteRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  /// See `DataGatewayRemoteDataSourceImpl._plainBody`.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  /// 4xx statuses worth retrying: an expired session (401), proxy
  /// authentication (407), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 407, 408, 429};

  /// 4xx statuses the API answers an invite request with, when it carries
  /// the envelope. 404 is handled apart, because it depends on the route.
  static const Set<int> _refusals = {400, 402, 403, 409, 410};

  @override
  Future<HouseholdInvite> send(
    String householdId,
    HouseholdInviteDraft draft,
  ) async {
    const action = 'Household invite send';
    final response = await _send(
      request: () => _dio.post<String>(
        _householdInvites(householdId),
        options: _plainBody,
        data: {
          ...switch (draft.invitee) {
            InviteeUser(:final userId) => {'inviteeId': userId},
            InviteeEmail(:final email) => {'inviteeEmail': email},
          },
          'inviteeName': ?draft.inviteeName,
          'role': _roleName(draft.role),
          'message': ?draft.message,
        },
      ),
      action: action,
      // An enveloped 404 here is the server saying the household is gone or
      // the user picked has no account. A server without the route answers
      // the same way, but the list on the screen before this one would have
      // failed first.
      rowRoute: true,
    );
    return _parse(
      () => _mapInvite(_inviteObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<PaginatedResult<HouseholdInvite>> fetchHouseholdInvites(
    String householdId, {
    HouseholdInviteStatus? status,
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.defaultPageSize,
  }) async {
    _checkPaging(
      page: page,
      limit: limit,
      max: HouseholdInviteRemoteDataSource.maxPageSize,
    );
    if (status == HouseholdInviteStatus.unknown) {
      throw ArgumentError.value(status, 'status', 'has no wire name');
    }

    const action = 'Household invite list';
    final response = await _send(
      request: () => _dio.get<String>(
        _householdInvites(householdId),
        options: _plainBody,
        queryParameters: {
          'page': page,
          'limit': limit,
          'status': ?status?.toWire(),
        },
      ),
      action: action,
      // A deleted household and a server without the route both answer an
      // enveloped 404 here, and they cannot be told apart. See the contract.
      rowRoute: false,
    );
    return _parse(
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'invites',
        item: _mapInvite,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<PaginatedResult<HouseholdInvite>> fetchInbox({
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.defaultPageSize,
  }) async {
    _checkPaging(
      page: page,
      limit: limit,
      max: HouseholdInviteRemoteDataSource.maxPageSize,
    );

    const action = 'Invite inbox';
    final response = await _send(
      request: () => _dio.get<String>(
        '/api/invites',
        options: _plainBody,
        queryParameters: {'page': page, 'limit': limit},
      ),
      action: action,
      rowRoute: false,
    );
    return _parse(
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'invites',
        item: _mapInvite,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<AcceptedHouseholdInvite> accept(String inviteId) async {
    const action = 'Household invite accept';
    final response = await _send(
      request: () =>
          _dio.post<String>('${_invite(inviteId)}/accept', options: _plainBody),
      action: action,
      rowRoute: true,
    );
    return _parse(
      () {
        final member = response.body['member'];
        if (member is! Map<String, dynamic>) {
          throw const FormatException('response is missing a "member" object');
        }
        return (
          invite: _mapInvite(_inviteObject(response.body)),
          householdId: member['householdId'] as String,
        );
      },
      action: action,
      status: response.status,
    );
  }

  @override
  Future<HouseholdInvite> decline(String inviteId) =>
      _change('${_invite(inviteId)}/decline', 'Household invite decline');

  @override
  Future<HouseholdInvite> withdraw(String inviteId) =>
      _change('${_invite(inviteId)}/withdraw', 'Household invite withdraw');

  @override
  Future<HouseholdInvite> revoke(String householdId, String inviteId) =>
      _change(
        '${_householdInvites(householdId)}/'
            '${Uri.encodeComponent(inviteId)}/revoke',
        'Household invite revoke',
      );

  @override
  Future<HouseholdInvite> approve(String householdId, String inviteId) =>
      _change(
        '${_householdInvites(householdId)}/'
            '${Uri.encodeComponent(inviteId)}/approve',
        'Household invite approve',
      );

  @override
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.maxSearchPageSize,
  }) async {
    final q = query.trim();
    const minLength = HouseholdInviteRemoteDataSource.minSearchLength;
    if (q.length < minLength) {
      throw ArgumentError.value(
        query,
        'query',
        'must be at least $minLength characters after trimming',
      );
    }
    _checkPaging(
      page: page,
      limit: limit,
      max: HouseholdInviteRemoteDataSource.maxSearchPageSize,
    );

    const action = 'User search';
    final response = await _send(
      request: () => _dio.get<String>(
        '/api/users/search',
        options: _plainBody,
        queryParameters: {'q': q, 'page': page, 'limit': limit},
      ),
      action: action,
      rowRoute: false,
    );
    return _parse(
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'users',
        item: _mapUser,
      ),
      action: action,
      status: response.status,
    );
  }

  static String _householdInvites(String householdId) =>
      '/api/households/${Uri.encodeComponent(householdId)}/invites';

  static String _invite(String inviteId) =>
      '/api/invites/${Uri.encodeComponent(inviteId)}';

  /// A POST to [path] answered by `{ message, invite }`.
  Future<HouseholdInvite> _change(String path, String action) async {
    final response = await _send(
      request: () => _dio.post<String>(path, options: _plainBody),
      action: action,
      rowRoute: true,
    );
    return _parse(
      () => _mapInvite(_inviteObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  // ── Mapping ─────────────────────────────────────────────────────────

  static Map<String, dynamic> _inviteObject(Map<String, dynamic> body) {
    final row = body['invite'];
    if (row is! Map<String, dynamic>) {
      throw const FormatException('response is missing an "invite" object');
    }
    return row;
  }

  /// Maps a server invite row to [HouseholdInvite], field by field.
  ///
  /// Explicit rather than generated, so the mapping reads only what the
  /// model holds. `inviteeEmail` and `message` are absent from some rows;
  /// `household` is present only on inbox rows.
  static HouseholdInvite _mapInvite(Map<String, dynamic> json) {
    final role = json['role'] as Map<String, dynamic>?;
    final household = json['household'] as Map<String, dynamic>?;
    return HouseholdInvite(
      id: json['id'] as String,
      status: HouseholdInviteStatus.fromWire(json['status'] as String),
      inviter: _mapUser(json['inviter'] as Map<String, dynamic>),
      role: role == null
          ? null
          : HouseholdRole.fromWire(role['name'] as String),
      inviteeName: json['inviteeName'] as String?,
      inviteeEmail: json['inviteeEmail'] as String?,
      message: json['message'] as String?,
      householdId: household?['id'] as String?,
      householdName: household?['name'] as String?,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// An embedded user: an inviter, or a search result. The display name is
  /// on the profile, which may be absent.
  static UserSummary _mapUser(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    return UserSummary(
      id: json['id'] as String,
      username: json['username'] as String,
      displayName: profile?['displayName'] as String?,
    );
  }

  /// The server's role name for an offerable role. The draft has already
  /// refused any other.
  static String _roleName(HouseholdRole role) => switch (role) {
    HouseholdRole.householdAdmin => 'HouseholdAdmin',
    HouseholdRole.householdMember => 'HouseholdMember',
    HouseholdRole.householdGuest => 'HouseholdGuest',
    HouseholdRole.householdOwner ||
    HouseholdRole.unknown => throw StateError('an invite cannot offer $role'),
  };

  // ── Request plumbing ────────────────────────────────────────────────

  /// Sends [request] and returns its decoded body, having converted every
  /// failure into a [HouseholdInviteRemoteException].
  ///
  /// [rowRoute] says whether the path names one invite or one household,
  /// which is what lets an application 404 mean that it is gone.
  Future<({Map<String, dynamic> body, int status})> _send({
    required Future<Response<String>> Function() request,
    required String action,
    required bool rowRoute,
  }) async {
    late final Response<String> response;
    try {
      response = await request();
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action, rowRoute: rowRoute);
    } on Object catch (error) {
      // Nothing else should escape Dio. `Object`, not `Exception`, so an
      // `Error` cannot break the "no raw transport error" promise either.
      throw HouseholdInviteTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw HouseholdInviteTransientException('$action returned no status');
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(
        status,
        '$action returned $status',
        cause: null,
        rowRoute: rowRoute,
        body: response.data,
      );
    }

    final raw = response.data;
    if (raw == null || raw.isEmpty) {
      throw HouseholdInvitePermanentException(
        '$action returned an empty body',
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = await decodeJsonBody(raw);
    } on FormatException catch (error) {
      throw HouseholdInvitePermanentException(
        '$action returned a body that is not JSON',
        statusCode: status,
        cause: error,
      );
    } on Object catch (error) {
      // The decode could not run (an isolate that would not spawn), which
      // says nothing about the response.
      throw HouseholdInviteTransientException(
        '$action could not be decoded',
        statusCode: status,
        cause: error,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw HouseholdInvitePermanentException(
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
      throw HouseholdInvitePermanentException(
        'Failed to parse the $action response: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  // ── Guards: requests the server is guaranteed to reject ─────────────

  void _checkPaging({required int page, required int limit, required int max}) {
    if (limit < 1 || limit > max) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $max (the server rejects a larger page '
            'rather than clamping it)',
      );
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'is 1-based');
    }
  }

  // ── Failure classification ──────────────────────────────────────────

  HouseholdInviteRemoteException _classifyDioException(
    DioException error, {
    required String action,
    required bool rowRoute,
  }) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        '$action failed with status $status',
        cause: error,
        rowRoute: rowRoute,
        body: error.response?.data,
      );
    }
    return HouseholdInviteTransientException('$action failed', cause: error);
  }

  HouseholdInviteRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
    required bool rowRoute,
    required Object? body,
  }) {
    if (status >= 500 || _retryable4xx.contains(status)) {
      return HouseholdInviteTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status == 409 && isRetryableRefusal(body)) {
      // A deadlock that outlived the server's own retry (#431). Read the
      // field, not the message, which is translated.
      return HouseholdInviteTransientException(
        '$message; the server hit a deadlock and asked for a retry',
        cause: cause,
        statusCode: status,
      );
    }

    // Every answer below is a conclusion about the caller or about a row,
    // and only the application's own envelope licenses one. A proxy or WAF
    // answers 403 and 404 too (#350, #365, #253).
    final fromApi = isApiErrorEnvelope(body, status);

    if (status == 403 && !fromApi) {
      return HouseholdInviteTransientException(
        '$message; the request did not reach the API',
        cause: cause,
        statusCode: status,
      );
    }
    if (status == 404) {
      // Nest answers an unregistered route with this same envelope, so only
      // a route naming an invite or a household can read it as "gone".
      return fromApi && rowRoute
          ? HouseholdInviteRefusedException(
              message,
              cause: cause,
              statusCode: status,
            )
          : HouseholdInviteTransientException(
              '$message; the route was not reachable',
              cause: cause,
              statusCode: status,
            );
    }
    if (fromApi && _refusals.contains(status)) {
      return HouseholdInviteRefusedException(
        message,
        cause: cause,
        statusCode: status,
        quota: status == 402 ? _quota(body) : null,
      );
    }
    if (status >= 400) {
      return HouseholdInvitePermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A 1xx or 3xx surfaced by a permissive validateStatus carries no
    // rejection.
    return HouseholdInviteTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }

  /// The limit a 402 hit, or null when its body does not say.
  static InviteQuota? _quota(Object? body) {
    final resource = apiErrorField(body, 'resource');
    final scope = apiErrorField(body, 'scope');
    if (resource == null || scope == null) return null;
    return InviteQuota(resource: resource, scope: scope);
  }
}
