import 'package:dio/dio.dart';
import 'package:dio_network/src/network/decode_json_body.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [NotificationRemoteDataSource] over a **per-server** Dio instance (#807).
///
/// Built like `AdminHouseholdRemoteDataSourceImpl`, except that the unread
/// list is a bare JSON array, which `sendForJson` (it wants an object) does
/// not take, so [fetchUnread] repeats its steps for an array. It does not
/// build or own its Dio.
///
/// Failure taxonomy per the [NotificationRemoteDataSource] contract.
class NotificationRemoteDataSourceImpl implements NotificationRemoteDataSource {
  const NotificationRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _unreadPath = '/api/notifications/unread';
  static const String _markReadPath = '/api/notifications/mark-read';
  static const _failures = RemoteFailureFamily<NotificationRemoteException>(
    transient: NotificationTransientException.new,
    permanent: NotificationPermanentException.new,
  );

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<List<UnreadNotification>> fetchUnread() async {
    const action = 'Unread notifications fetch';
    final Response<String> response;
    try {
      response = await _dio.get<String>(_unreadPath, options: _plainBody);
    } on DioException catch (error) {
      throw failureForDioException(_failures, error, action: action);
    } on Object catch (error) {
      throw _failures.transient('$action failed unexpectedly', cause: error);
    }

    final status = response.statusCode;
    if (status == null) {
      throw _failures.transient('$action returned no status');
    }
    if (status < 200 || status >= 300) {
      throw failureForStatus(
        _failures,
        status,
        '$action returned $status',
        body: response.data,
        cause: null,
      );
    }

    final raw = response.data;
    if (raw == null || raw.isEmpty) {
      throw _failures.permanent(
        '$action returned an empty body',
        statusCode: status,
      );
    }
    final Object? decoded;
    try {
      decoded = await decodeJsonBody(raw);
    } on FormatException catch (error) {
      throw _failures.permanent(
        '$action returned a body that is not JSON',
        statusCode: status,
        cause: error,
      );
    } on Object catch (error) {
      // An isolate that would not spawn: local and momentary, not a statement
      // about the response.
      throw _failures.transient(
        '$action could not be decoded',
        statusCode: status,
        cause: error,
      );
    }
    if (decoded is! List) {
      throw _failures.permanent(
        '$action returned a body that is not a JSON array',
        statusCode: status,
      );
    }
    final entries = decoded;

    return parseRemote(
      _failures,
      () => [for (final entry in entries) _mapEntry(entry)],
      action: action,
      status: status,
    );
  }

  @override
  Future<void> markRead(List<String> ids) async {
    if (ids.isEmpty) {
      throw ArgumentError.value(ids, 'ids', 'must not be empty');
    }
    await sendForJson(
      () => _dio.post<String>(
        _markReadPath,
        // No `userId`, deliberately: see the interface's markRead doc and
        // BoardGamesEmpire/board-games-empire-backend#584.
        data: {'notificationIds': ids},
        options: _plainBody,
      ),
      action: 'Notifications mark read',
      family: _failures,
      readBody: false,
    );
  }

  /// One `{ id, type, payload, read, createdAt }` entry. A malformed one
  /// throws, which fails the whole read.
  static UnreadNotification _mapEntry(Object? entry) {
    if (entry is! Map<String, dynamic>) {
      throw FormatException(
        'notification entry is ${entry.runtimeType}, expected an object',
      );
    }
    final payload = entry['payload'];
    if (payload is! Map<String, dynamic>) {
      throw FormatException(
        'notification "payload" is ${payload.runtimeType}, expected an object',
      );
    }
    return UnreadNotification(
      id: entry['id'] as String,
      type: entry['type'] as String,
      payload: payload,
      createdAt: DateTime.parse(entry['createdAt'] as String),
    );
  }
}
