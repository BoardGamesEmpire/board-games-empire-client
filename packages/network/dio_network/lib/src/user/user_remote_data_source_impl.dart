import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/decode_json_body.dart';
import 'user_summary_json.dart';

/// [UserRemoteDataSource] over a **per-server** Dio instance (#499).
///
/// Built on the DataGateway source's request plumbing (#41): the body is asked
/// for as a `String` with the response type pinned on every request, decoded
/// here after the status is read, and probed for the API's error envelope with
/// a bounded synchronous parse. It does not build or own its Dio; the network
/// installer constructs it from the per-server container.
///
/// Failure taxonomy per the [UserRemoteDataSource] contract.
class UserRemoteDataSourceImpl implements UserRemoteDataSource {
  const UserRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _searchPath = '/api/users/search';

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  /// 4xx statuses worth retrying: an expired session (401), proxy
  /// authentication (407), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 407, 408, 429};

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
    final response = await _send(
      request: () => _dio.get<String>(
        _searchPath,
        options: _plainBody,
        queryParameters: {'q': q, 'page': page, 'limit': limit},
      ),
      action: action,
    );
    return _parse(
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'users',
        item: userSummaryFromJson,
      ),
      action: action,
      status: response.status,
    );
  }

  // ── Request plumbing ────────────────────────────────────────────────
  //
  // Another copy of the remotes' request and classification plumbing: `_send`
  // here, and the failure classification at the end of the file. #260 is where
  // the classification would become one.

  /// Sends [request] and returns its decoded body, having converted every
  /// failure into a [UserRemoteException].
  Future<({Map<String, dynamic> body, int status})> _send({
    required Future<Response<String>> Function() request,
    required String action,
  }) async {
    late final Response<String> response;
    try {
      response = await request();
    } on DioException catch (error) {
      throw _classifyDioException(error, action: action);
    } on Object catch (error) {
      // Nothing else should escape Dio. `Object`, not `Exception`, so an
      // `Error` cannot break the "no raw transport error" promise either.
      throw UserRemoteTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw UserRemoteTransientException('$action returned no status');
    }
    if (status < 200 || status >= 300) {
      throw _classifyStatus(
        status,
        '$action returned $status',
        cause: null,
        body: response.data,
      );
    }

    final raw = response.data;
    if (raw == null || raw.isEmpty) {
      throw UserRemotePermanentException(
        '$action returned an empty body',
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = await decodeJsonBody(raw);
    } on FormatException catch (error) {
      throw UserRemotePermanentException(
        '$action returned a body that is not JSON',
        statusCode: status,
        cause: error,
      );
    } on Object catch (error) {
      // The decode could not run (an isolate that would not spawn), which
      // says nothing about the response.
      throw UserRemoteTransientException(
        '$action could not be decoded',
        statusCode: status,
        cause: error,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw UserRemotePermanentException(
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
      throw UserRemotePermanentException(
        'Failed to parse the $action response: $error',
        statusCode: status,
        cause: error,
      );
    }
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

  // ── Failure classification ──────────────────────────────────────────

  UserRemoteException _classifyDioException(
    DioException error, {
    required String action,
  }) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        '$action failed with status $status',
        cause: error,
        body: error.response?.data,
      );
    }
    return UserRemoteTransientException('$action failed', cause: error);
  }

  UserRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
    required Object? body,
  }) {
    if (status >= 500 || _retryable4xx.contains(status)) {
      return UserRemoteTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status == 409 && isRetryableRefusal(body)) {
      // A deadlock that outlived the server's own retry (#431). Read the
      // field, not the message, which is translated.
      return UserRemoteTransientException(
        '$message; the server hit a deadlock and asked for a retry',
        cause: cause,
        statusCode: status,
      );
    }

    // A 403 is a conclusion about the caller, and only the application's own
    // envelope licenses one. A proxy or WAF answers 403 too (#350, #365).
    if (status == 403 && !isApiErrorEnvelope(body, status)) {
      return UserRemoteTransientException(
        '$message; the request did not reach the API',
        cause: cause,
        statusCode: status,
      );
    }
    if (status == 404) {
      // Search is a list route, which is never absent for a caller who reached
      // it: no matches is a 200 with an empty page. Nest answers an
      // unregistered route with this same envelope, so a 404 here, enveloped
      // or not, means the route is not reachable, such as on a server without
      // it.
      return UserRemoteTransientException(
        '$message; the route was not reachable',
        cause: cause,
        statusCode: status,
      );
    }
    if (status >= 400) {
      // Every other 4xx, one carrying the envelope included, is the
      // application rejecting the request, and the same request is rejected
      // again.
      return UserRemotePermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A 1xx or 3xx surfaced by a permissive validateStatus carries no
    // rejection.
    return UserRemoteTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
