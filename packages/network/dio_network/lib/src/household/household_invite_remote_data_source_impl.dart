import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/remote_failure.dart';
import '../user/user_summary_json.dart';

/// [HouseholdInviteRemoteDataSource] over a **per-server** Dio instance
/// (#455).
///
/// The body is asked for as a `String` with the response type pinned on
/// every request, and `sendForJson` decodes it after the status is read and
/// classifies a failure through [_InviteFailures]. It does not build or own
/// its Dio; the network installer constructs it from the per-server
/// container.
///
/// Failure taxonomy per the [HouseholdInviteRemoteDataSource] contract.
class HouseholdInviteRemoteDataSourceImpl
    implements HouseholdInviteRemoteDataSource {
  const HouseholdInviteRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  /// See `DataGatewayRemoteDataSourceImpl._plainBody`.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  /// 4xx statuses the API answers an invite request with, when it carries
  /// the envelope. 404 is handled apart, because it depends on the route.
  static const Set<int> _refusals = {400, 402, 403, 409, 410};

  @override
  Future<HouseholdInvite> send(
    String householdId,
    HouseholdInviteDraft draft,
  ) async {
    const action = 'Household invite send';
    const failures = _InviteFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.post<String>(
        _householdInvites(householdId),
        options: _plainBody,
        data: {
          ...switch (draft.invitee) {
            InviteeUser(:final userId) => {'inviteeId': userId},
            InviteeEmail(:final email) => {'inviteeEmail': email},
          },
          'inviteeName': ?draft.inviteeName,
          'role': draft.role.toWire(),
          'message': ?draft.message,
        },
      ),
      action: action,
      // An enveloped 404 here is the server saying the household is gone or
      // the user picked has no account. A server without the route answers
      // the same way, but the list on the screen before this one would have
      // failed first.
      family: failures,
    );
    return parseRemote(
      failures,
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
  }) =>
      // A deleted household and a server without the route both answer an
      // enveloped 404 here, and they cannot be told apart. See the contract.
      _fetchPage(
        _householdInvites(householdId),
        action: 'Household invite list',
        status: status,
        page: page,
        limit: limit,
      );

  @override
  Future<PaginatedResult<HouseholdInvite>> fetchInbox({
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.defaultPageSize,
  }) => _fetchPage(
    '/api/invites',
    action: 'Invite inbox',
    page: page,
    limit: limit,
  );

  @override
  Future<PaginatedResult<HouseholdInvite>> fetchSent({
    HouseholdInviteStatus? status,
    int page = 1,
    int limit = HouseholdInviteRemoteDataSource.defaultPageSize,
  }) => _fetchPage(
    '/api/invites/sent',
    action: 'Sent invites',
    status: status,
    page: page,
    limit: limit,
  );

  /// Reads one page of invites from the list at [path], narrowed to
  /// [status] when one is given. A list's 404 never says a row is gone, so
  /// none is a row route; the household's list included, for the reason on
  /// [fetchHouseholdInvites].
  Future<PaginatedResult<HouseholdInvite>> _fetchPage(
    String path, {
    required String action,
    required int page,
    required int limit,
    HouseholdInviteStatus? status,
  }) async {
    _checkPaging(
      page: page,
      limit: limit,
      max: HouseholdInviteRemoteDataSource.maxPageSize,
    );
    if (status == HouseholdInviteStatus.unknown) {
      throw ArgumentError.value(status, 'status', 'has no wire name');
    }

    const failures = _InviteFailures();
    final response = await sendForJson(
      () => _dio.get<String>(
        path,
        options: _plainBody,
        queryParameters: {
          'page': page,
          'limit': limit,
          'status': ?status?.toWire(),
        },
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
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
    const failures = _InviteFailures(rowRoute: true);
    final response = await sendForJson(
      () =>
          _dio.post<String>('${_invite(inviteId)}/accept', options: _plainBody),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
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

  static String _householdInvites(String householdId) =>
      '/api/households/${Uri.encodeComponent(householdId)}/invites';

  static String _invite(String inviteId) =>
      '/api/invites/${Uri.encodeComponent(inviteId)}';

  /// A POST to [path] answered by `{ message, invite }`.
  Future<HouseholdInvite> _change(String path, String action) async {
    const failures = _InviteFailures(rowRoute: true);
    final response = await sendForJson(
      () => _dio.post<String>(path, options: _plainBody),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
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
  /// `household` is present only on inbox and sent rows.
  static HouseholdInvite _mapInvite(Map<String, dynamic> json) {
    final role = json['role'] as Map<String, dynamic>?;
    final household = json['household'] as Map<String, dynamic>?;
    return HouseholdInvite(
      id: json['id'] as String,
      status: HouseholdInviteStatus.fromWire(json['status'] as String),
      inviter: userSummaryFromJson(json['inviter'] as Map<String, dynamic>),
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

  /// The limit a 402 hit, or null when its body does not say.
  static InviteQuota? _quota(Object? body) {
    final resource = apiErrorField(body, 'resource');
    final scope = apiErrorField(body, 'scope');
    if (resource == null || scope == null) return null;
    return InviteQuota(resource: resource, scope: scope);
  }
}

/// How the invite source builds its failures for the shared classifier.
final class _InviteFailures
    extends RemoteFailureFamily<HouseholdInviteRemoteException> {
  const _InviteFailures({this.rowRoute = false})
    : super(
        transient: HouseholdInviteTransientException.new,
        permanent: HouseholdInvitePermanentException.new,
      );

  /// Whether the path names one invite or one household, which is what lets
  /// an application 404 mean that it is gone.
  final bool rowRoute;

  /// Every answer here is a conclusion about the caller or about a row, and
  /// only the application's own envelope licenses one, so a refusal needs
  /// [RemoteRefusal.fromApi]. The set is
  /// [HouseholdInviteRemoteDataSourceImpl._refusals], plus a 404 on a
  /// [rowRoute]: Nest answers an unregistered route with the same envelope,
  /// so only a route naming an invite or a household can read it as "gone".
  /// Any other 404 takes the shared default, transient.
  @override
  HouseholdInviteRemoteException? refused(RemoteRefusal refusal) {
    final status = refusal.status;
    if (!refusal.fromApi) return null;
    if (!HouseholdInviteRemoteDataSourceImpl._refusals.contains(status) &&
        !(status == 404 && rowRoute)) {
      return null;
    }
    return HouseholdInviteRefusedException(
      refusal.message,
      statusCode: status,
      cause: refusal.cause,
      quota: status == 402
          ? HouseholdInviteRemoteDataSourceImpl._quota(refusal.body)
          : null,
    );
  }
}
