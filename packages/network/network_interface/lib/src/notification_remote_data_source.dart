import 'package:models/domain.dart';

/// Remote data source for the signed-in user's notifications (#807).
///
/// Implementations run over a **per-server** authenticated transport, like
/// [DataGatewayRemoteDataSource]: the injected client carries the base URL and
/// the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend notifications, under the `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchUnread] | `GET /api/notifications/unread` | a bare array of `{ id, type, payload, read, createdAt }`, newest first |
/// | [fetchPage] | `GET /api/notifications?limit=<n>[&cursor=<c>]` | `{ notifications: [{ id, type, payload, read, readAt, createdAt }], pagination: { limit, hasMore, nextCursor } }`, newest first; `nextCursor` is null on the last page |
/// | [fetchUnreadCount] | `GET /api/notifications/unread/count` | `{ count }` |
/// | [markRead] | `POST /api/notifications/mark-read` | `{ notificationIds: [...] }`, at most [maxIds] |
/// | [markAllRead] | `POST /api/notifications/mark-all-read` | none |
///
/// The cursor is opaque: pass it back exactly as received.
///
/// ## Failures
///
/// - [NotificationTransientException] and [NotificationPermanentException]:
///   the shared rules.
/// - [ArgumentError], unwrapped, before any request: from [markRead] for an
///   empty list or more than [maxIds] ids, and from [fetchPage] for a limit
///   outside 1 to [maxPageSize].
abstract class NotificationRemoteDataSource {
  /// The most ids one [markRead] takes (#1120).
  static const int maxIds = 100;

  /// The page size [fetchPage] asks for by default.
  static const int defaultPageSize = 25;

  /// The largest page size [fetchPage] accepts.
  static const int maxPageSize = 100;

  /// The caller's unread notifications, newest first.
  Future<List<UnreadNotification>> fetchUnread();

  /// One page of the caller's notifications, read ones included, newest
  /// first. [cursor] is the previous page's [NotificationPage.nextCursor],
  /// or null for the first page.
  ///
  /// One malformed entry doesn't fail the page (#475): a payload that isn't
  /// an object reads as empty, and an entry with no readable id, type or
  /// creation time is left out. Only a broken page envelope fails it.
  ///
  /// Throws [ArgumentError] for a [limit] outside 1 to [maxPageSize], before
  /// any request.
  Future<NotificationPage> fetchPage({
    String? cursor,
    int limit = defaultPageSize,
  });

  /// How many notifications the caller has not read.
  Future<int> fetchUnreadCount();

  /// Marks every notification the caller holds read.
  Future<void> markAllRead();

  /// Marks the notifications [ids] read.
  ///
  /// The body is `{ notificationIds }` alone, and it takes at most [maxIds].
  /// Throws [ArgumentError] for an empty list or more than [maxIds] ids,
  /// before any request (#1120).
  Future<void> markRead(List<String> ids);
}

/// Base class for every notification remote failure.
sealed class NotificationRemoteException implements Exception {
  const NotificationRemoteException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      // toString names the concrete subclass, so it needs the runtime type.
      // ignore: no_runtimetype_tostring
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The server refused the request, and sending it again will not change that.
final class NotificationPermanentException extends NotificationRemoteException {
  const NotificationPermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class NotificationTransientException extends NotificationRemoteException {
  const NotificationTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
