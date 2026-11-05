import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/remote_failure.dart';
import 'household_member_json.dart';

/// [HouseholdMemberRemoteDataSource] over a **per-server** Dio instance
/// (#480, #483).
///
/// The body is asked for as a `String` with the response type pinned on
/// every request, and `sendForJson` decodes it after the status is read and
/// classifies a failure through [_MemberFailures]. It does not build or own
/// its Dio; the network installer constructs it from the per-server
/// container.
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
    const failures = _MemberFailures();
    final response = await sendForJson(
      request,
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
        return mapHouseholdMember(member);
      },
      action: action,
      status: response.status,
    );
  }
}

/// How the member source builds its failures for the shared classifier.
final class _MemberFailures
    extends RemoteFailureFamily<HouseholdMemberRemoteException> {
  const _MemberFailures()
    : super(
        transient: HouseholdMemberTransientException.new,
        permanent: HouseholdMemberPermanentException.new,
      );

  /// An enveloped answer in [HouseholdMemberRemoteDataSourceImpl._refusals]
  /// is a refusal, a conclusion about the caller or a row that only the
  /// application's own envelope licenses. The enveloped 404 is one like the
  /// rest: Nest answers an unregistered route with the same envelope, so it
  /// does not say the member is gone, only that the API said no; what it
  /// means is the caller's to decide (#122).
  @override
  HouseholdMemberRemoteException? refused(RemoteRefusal refusal) =>
      refusal.fromApi &&
          HouseholdMemberRemoteDataSourceImpl._refusals.contains(refusal.status)
      ? HouseholdMemberRefusedException(
          refusal.message,
          statusCode: refusal.status,
          cause: refusal.cause,
        )
      : null;
}
