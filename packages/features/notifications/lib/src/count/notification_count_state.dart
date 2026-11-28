import 'package:equatable/equatable.dart';

/// The most the bell badge counts to before it reads `99+`.
const int _badgeCap = 99;

/// The text on the bell's badge for [unread] notifications: the count, or
/// `99+` above 99 (#475).
String unreadBadgeText(int unread) =>
    unread > _badgeCap ? '$_badgeCap+' : '$unread';

/// How many notifications the signed-in user has not read (#475).
final class NotificationCountState extends Equatable {
  const NotificationCountState({this.unread, this.refreshing = false});

  /// The unread count, or null until the first read lands.
  final int? unread;

  /// Whether a read of the count is in flight.
  final bool refreshing;

  NotificationCountState copyWith({int? unread, bool? refreshing}) =>
      NotificationCountState(
        unread: unread ?? this.unread,
        refreshing: refreshing ?? this.refreshing,
      );

  @override
  List<Object?> get props => [unread, refreshing];
}
