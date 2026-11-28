import 'package:dio/dio.dart';
import 'package:dio_network/src/network/decode_json_body.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [NotificationRemoteDataSource] over a **per-server** Dio instance (#807).
///
/// Built like `AdminHouseholdRemoteDataSourceImpl`, except that the unread
/// list is a bare JSON array, which `sendForJson` (it wants an object) does
/// not take, so [fetchUnread] repeats its steps for an array. The page and the
/// count are objects, and go through it. It does not
/// build or own its Dio.
///
/// Failure taxonomy per the [NotificationRemoteDataSource] contract.
class NotificationRemoteDataSourceImpl implements NotificationRemoteDataSource {
  const NotificationRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _unreadPath = '/api/notifications/unread';
  static const String _markReadPath = '/api/notifications/mark-read';
  static const String _markAllReadPath = '/api/notifications/mark-all-read';
  static const String _pagePath = '/api/notifications';
  static const String _unreadCountPath = '/api/notifications/unread/count';

  // The wire keys of the page and count answers (#475), in one place.
  static const String _limitParam = 'limit';
  static const String _cursorParam = 'cursor';
  static const String _notificationsKey = 'notifications';
  static const String _paginationKey = 'pagination';
  static const String _hasMoreKey = 'hasMore';
  static const String _nextCursorKey = 'nextCursor';
  static const String _countKey = 'count';

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
    if (ids.length > NotificationRemoteDataSource.maxIds) {
      throw ArgumentError.value(
        ids.length,
        'ids',
        'must be at most ${NotificationRemoteDataSource.maxIds}',
      );
    }
    await sendForJson(
      () => _dio.post<String>(
        _markReadPath,
        // The server takes the ids alone.
        data: {'notificationIds': ids},
        options: _plainBody,
      ),
      action: 'Notifications mark read',
      family: _failures,
      readBody: false,
    );
  }

  @override
  Future<void> markAllRead() async {
    await sendForJson(
      () => _dio.post<String>(_markAllReadPath, options: _plainBody),
      action: 'Notifications mark all read',
      family: _failures,
      readBody: false,
    );
  }

  @override
  Future<NotificationPage> fetchPage({
    String? cursor,
    int limit = NotificationRemoteDataSource.defaultPageSize,
  }) async {
    if (limit < 1 || limit > NotificationRemoteDataSource.maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be 1 to ${NotificationRemoteDataSource.maxPageSize}',
      );
    }
    return sendForParsed(
      () => _dio.get<String>(
        _pagePath,
        // Dio encodes the cursor; the server decodes it back to what it sent.
        queryParameters: {_limitParam: limit, _cursorParam: ?cursor},
        options: _plainBody,
      ),
      action: 'Notifications page fetch',
      family: _failures,
      map: (body) {
        final notifications = body[_notificationsKey];
        if (notifications is! List) {
          throw FormatException(
            '"$_notificationsKey" is ${notifications.runtimeType}, '
            'expected an array',
          );
        }
        final pagination = body[_paginationKey];
        if (pagination is! Map<String, dynamic>) {
          throw FormatException(
            '"$_paginationKey" is ${pagination.runtimeType}, '
            'expected an object',
          );
        }
        // Both say whether a page follows. One missing, or the two
        // disagreeing, would otherwise end the list early with no error.
        if (!pagination.containsKey(_nextCursorKey)) {
          throw const FormatException(
            '"$_paginationKey.$_nextCursorKey" is missing',
          );
        }
        final nextCursor = pagination[_nextCursorKey];
        if (nextCursor != null && nextCursor is! String) {
          throw FormatException(
            '"$_paginationKey.$_nextCursorKey" is ${nextCursor.runtimeType}, '
            'expected a string or null',
          );
        }
        final hasMore = pagination[_hasMoreKey];
        if (hasMore is! bool) {
          throw FormatException(
            '"$_paginationKey.$_hasMoreKey" is ${hasMore.runtimeType}, '
            'expected a bool',
          );
        }
        if (hasMore != (nextCursor != null)) {
          throw FormatException(
            '"$_paginationKey.$_hasMoreKey" is $hasMore, but '
            '"$_nextCursorKey" is ${nextCursor == null ? 'null' : 'a cursor'}',
          );
        }
        return NotificationPage(
          items: [
            for (final entry in notifications) ?_mapUserEntry(entry),
          ],
          nextCursor: nextCursor as String?,
        );
      },
    );
  }

  @override
  Future<int> fetchUnreadCount() => sendForParsed(
    () => _dio.get<String>(_unreadCountPath, options: _plainBody),
    action: 'Unread notification count fetch',
    family: _failures,
    map: (body) {
      final count = body[_countKey];
      if (count is! int || count < 0) {
        throw FormatException(
          '"$_countKey" is $count, expected a non-negative integer',
        );
      }
      return count;
    },
  );

  /// One `{ id, type, payload, read, readAt, createdAt }` entry, or null
  /// for one the page can't show.
  ///
  /// One bad entry doesn't fail the page (#475). A `payload` that isn't an
  /// object reads as `{}`, which presents as a plain row; a `read` that
  /// isn't a bool follows `readAt`; a `readAt` that can't be parsed is null.
  /// An entry that isn't an object, or whose `id`, `type` or `createdAt`
  /// can't be read, is left out: it could be neither shown nor marked read.
  static UserNotification? _mapUserEntry(Object? entry) {
    if (entry is! Map<String, dynamic>) return null;
    final id = entry['id'];
    final type = entry['type'];
    final createdAt = _dateOrNull(entry['createdAt']);
    if (id is! String || type is! String || createdAt == null) return null;
    final payload = entry['payload'];
    final readAt = _dateOrNull(entry['readAt']);
    final read = entry['read'];
    return UserNotification(
      id: id,
      type: type,
      payload: payload is Map<String, dynamic>
          ? payload
          : const <String, dynamic>{},
      read: read is bool ? read : readAt != null,
      readAt: readAt,
      createdAt: createdAt,
    );
  }

  /// [value] as a timestamp, or null when it is not an ISO-8601 string.
  static DateTime? _dateOrNull(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  /// One `{ id, type, payload, read, createdAt }` entry, validated: an
  /// object, with an object `payload`, string `id` and `type` and a date
  /// `createdAt`. Anything else throws, which fails the whole read.
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
