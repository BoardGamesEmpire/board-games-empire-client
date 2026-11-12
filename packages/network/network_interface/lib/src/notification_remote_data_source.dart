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
/// | [markRead] | `POST /api/notifications/mark-read` | `{ notificationIds: [...] }` |
///
/// ## Failures
///
/// - [NotificationTransientException] and [NotificationPermanentException]:
///   the shared rules.
/// - [ArgumentError], unwrapped, from [markRead]: an empty list.
abstract class NotificationRemoteDataSource {
  /// The caller's unread notifications, newest first.
  Future<List<UnreadNotification>> fetchUnread();

  /// Marks the notifications [ids] read.
  ///
  /// Throws [ArgumentError] for an empty list, before any request.
  ///
  /// Until BoardGamesEmpire/board-games-empire-backend#584 lands, the
  /// server's `MarkReadDto` also requires a `userId`, which it ignores (it
  /// marks the caller's own), so it answers 400 to this body. The field is
  /// left out on purpose: that change removes it, and the server's pipe then
  /// refuses any field the DTO doesn't declare. Callers treat a failure as
  /// non-fatal.
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
