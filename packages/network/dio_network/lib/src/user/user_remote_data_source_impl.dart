import 'package:dio/dio.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:dio_network/src/user/user_access_json.dart';
import 'package:dio_network/src/user/user_summary_json.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [UserRemoteDataSource] over a **per-server** Dio instance (#499).
///
/// The body is asked for as a `String` with the response type pinned on
/// every request, and `sendForJson` decodes it after the status is read and
/// classifies a failure through [_failures]. It does not build or own
/// its Dio; the network installer constructs it from the per-server
/// container.
///
/// Failure taxonomy per the [UserRemoteDataSource] contract.
class UserRemoteDataSourceImpl implements UserRemoteDataSource {
  const UserRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _searchPath = '/api/users/search';
  static const String _accessPath = '/api/users/me/access';

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = UserRemoteDataSource.maxSearchPageSize,
  }) async {
    final q = query.trim();
    const minLength = UserRemoteDataSource.minSearchLength;
    if (q.length < minLength) {
      throw ArgumentError.value(
        query,
        'query',
        'must be at least $minLength characters after trimming',
      );
    }
    _checkPaging(page: page, limit: limit);

    const action = 'User search';
    final response = await sendForJson(
      () => _dio.get<String>(
        _searchPath,
        options: _plainBody,
        queryParameters: {'q': q, 'page': page, 'limit': limit},
      ),
      action: action,
      family: _failures,
    );
    return parseRemote(
      _failures,
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'users',
        item: userSummaryFromJson,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<Map<ResourceType, ResourceAccess>> fetchAccess(
    Set<ResourceType> resourceTypes,
  ) async {
    if (resourceTypes.isEmpty) {
      throw ArgumentError.value(
        resourceTypes,
        'resourceTypes',
        'must not be empty (the server rejects an empty list)',
      );
    }

    const action = 'Caller access';
    final response = await sendForJson(
      () => _dio.get<String>(
        _accessPath,
        options: _plainBody,
        queryParameters: {
          'resourceTypes': resourceTypes.map((type) => type.wireName).join(','),
        },
      ),
      action: action,
      family: _failures,
    );
    return parseRemote(
      _failures,
      () => callerAccessFromJson(response.body, resourceTypes),
      action: action,
      status: response.status,
    );
  }

  // ── Guards: requests the server is guaranteed to reject ─────────────

  void _checkPaging({required int page, required int limit}) {
    const maxPageSize = UserRemoteDataSource.maxSearchPageSize;
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
  }
}

/// How the user source builds its failures for the shared classifier.
///
/// Every route is a list or self route, never absent for a caller who reached
/// it, so the source claims no refusal of its own and the shared defaults
/// apply.
const _failures = RemoteFailureFamily<UserRemoteException>(
  transient: UserRemoteTransientException.new,
  permanent: UserRemotePermanentException.new,
);
