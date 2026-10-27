import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/decode_json_body.dart';
import 'household_member_json.dart';

/// [HouseholdMemberRemoteDataSource] over a **per-server** Dio instance
/// (#480, #483).
///
/// Built on the invite source's request plumbing (#455): the body is asked
/// for as a `String` with the response type pinned on every request, decoded
/// here after the status is read, and probed for the API's error envelope
/// with a bounded synchronous parse. It does not build or own its Dio; the
/// network installer constructs it from the per-server container.
///
/// Failure taxonomy per the [HouseholdMemberRemoteDataSource] contract. Both
/// routes name a member row, so unlike the invite source there is no route
/// whose enveloped 404 is read as an absent route: every one is a refusal,
/// and the caller decides what it means.
class HouseholdMemberRemoteDataSourceImpl
    implements HouseholdMemberRemoteDataSource {
  const HouseholdMemberRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  /// See `DataGatewayRemoteDataSourceImpl._plainBody`.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  /// 4xx statuses worth retrying: an expired session (401), proxy
  /// authentication (407), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 407, 408, 429};

  /// 4xx statuses the API answers a member request with, when it carries the
  /// envelope.
  static const Set<int> _refusals = {400, 403, 404, 409};

  @override
  Future<HouseholdMember> changeRole(
    String householdId,
    String memberId,
    HouseholdRole role,
  ) async {
    if (!HouseholdMemberRemoteDataSource.assignableRoles.contains(role)) {
      throw ArgumentError.value(
        role,
        'role',
        'not a role a member can be given',
      );
    }
    return _sendForMember(
      () => _dio.patch<String>(
        '${_member(householdId, memberId)}/role',
        options: _plainBody,
        data: {'role': role.toWire()},
      ),
      action: 'Household member role change',
    );
  }

  @override
  Future<HouseholdMember> remove(String householdId, String memberId) =>
      _sendForMember(
        () => _dio.delete<String>(
          _member(householdId, memberId),
          options: _plainBody,
        ),
        action: 'Household member remove',
      );

  static String _member(String householdId, String memberId) =>
      '/api/households/${Uri.encodeComponent(householdId)}'
      '/members/${Uri.encodeComponent(memberId)}';

  /// Sends [request] and reads the `{ message, member }` answer the two
  /// routes share.
  Future<HouseholdMember> _sendForMember(
    Future<Response<String>> Function() request, {
    required String action,
  }) async {
    final response = await _send(request, action: action);
    return _parse(
      () {
        final member = response.body['member'];
        if (member is! Map<String, dynamic>) {
          throw const FormatException('response is missing a "member" object');
        }
        return mapHouseholdMember(member);
      },
      action: action,
      status: response.status,
    );
  }

  // ── Request plumbing ────────────────────────────────────────────────

  /// Sends [request] and returns its decoded body, having converted every
  /// failure into a [HouseholdMemberRemoteException].
  Future<({Map<String, dynamic> body, int status})> _send(
    Future<Response<String>> Function() request, {
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
      throw HouseholdMemberTransientException(
        '$action failed unexpectedly',
        cause: error,
      );
    }

    final status = response.statusCode;
    if (status == null) {
      throw HouseholdMemberTransientException('$action returned no status');
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
      throw HouseholdMemberPermanentException(
        '$action returned an empty body',
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = await decodeJsonBody(raw);
    } on FormatException catch (error) {
      throw HouseholdMemberPermanentException(
        '$action returned a body that is not JSON',
        statusCode: status,
        cause: error,
      );
    } on Object catch (error) {
      // The decode could not run (an isolate that would not spawn), which
      // says nothing about the response.
      throw HouseholdMemberTransientException(
        '$action could not be decoded',
        statusCode: status,
        cause: error,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw HouseholdMemberPermanentException(
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
      throw HouseholdMemberPermanentException(
        'Failed to parse the $action response: $error',
        statusCode: status,
        cause: error,
      );
    }
  }

  // ── Failure classification ──────────────────────────────────────────

  HouseholdMemberRemoteException _classifyDioException(
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
    return HouseholdMemberTransientException('$action failed', cause: error);
  }

  HouseholdMemberRemoteException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
    required Object? body,
  }) {
    if (status >= 500 || _retryable4xx.contains(status)) {
      return HouseholdMemberTransientException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status == 409 && isRetryableRefusal(body)) {
      // A deadlock that outlived the server's own retry (#431). Read the
      // field, not the message, which is translated.
      return HouseholdMemberTransientException(
        '$message; the server hit a deadlock and asked for a retry',
        cause: cause,
        statusCode: status,
      );
    }

    // Every answer below is a conclusion about the caller or about a row,
    // and only the application's own envelope licenses one. A proxy or WAF
    // answers 403 and 404 too (#350, #365, #253).
    final fromApi = isApiErrorEnvelope(body, status);

    if ((status == 403 || status == 404) && !fromApi) {
      return HouseholdMemberTransientException(
        '$message; the request did not reach the API',
        cause: cause,
        statusCode: status,
      );
    }
    // An enveloped 404 is a refusal like the rest. Nest answers an
    // unregistered route with the same envelope, so it does not say the
    // member is gone, only that the API said no; what it means is the
    // caller's to decide (#122).
    if (fromApi && _refusals.contains(status)) {
      return HouseholdMemberRefusedException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status >= 400) {
      return HouseholdMemberPermanentException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A 1xx or 3xx surfaced by a permissive validateStatus carries no
    // rejection.
    return HouseholdMemberTransientException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
