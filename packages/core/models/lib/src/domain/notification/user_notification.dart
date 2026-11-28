import 'package:equatable/equatable.dart';

/// A notification the server holds for the caller, read or not (#475).
/// [type] says how to read [payload].
///
/// `UnreadNotification` is the unread-only shape `MailTestBloc` polls; this is
/// the history entry, which also says whether and when it was read.
final class UserNotification extends Equatable {
  const UserNotification({
    required this.id,
    required this.type,
    required this.payload,
    required this.read,
    required this.createdAt,
    this.readAt,
  });

  final String id;
  final String type;
  final Map<String, Object?> payload;
  final bool read;

  /// When the caller read it, or null while it is unread.
  final DateTime? readAt;
  final DateTime createdAt;

  /// This notification, read at [at]. Nothing else changes.
  UserNotification markedRead(DateTime at) => UserNotification(
    id: id,
    type: type,
    payload: payload,
    read: true,
    readAt: at,
    createdAt: createdAt,
  );

  @override
  List<Object?> get props => [id, type, payload, read, readAt, createdAt];
}

/// One page of the caller's notifications, newest first (#475).
final class NotificationPage extends Equatable {
  const NotificationPage({required this.items, this.nextCursor});

  final List<UserNotification> items;

  /// The opaque cursor for the next page, or null on the last one. Pass it
  /// back exactly as received.
  final String? nextCursor;

  bool get hasMore => nextCursor != null;

  @override
  List<Object?> get props => [items, nextCursor];
}
