import 'package:equatable/equatable.dart';

/// Input to the notification list (#475).
sealed class NotificationListEvent extends Equatable {
  const NotificationListEvent();

  @override
  List<Object?> get props => [];
}

/// Read the first page, from nothing: what the list shows when it opens, and
/// what Retry asks for after a failed load.
final class NotificationListLoadRequested extends NotificationListEvent {
  const NotificationListLoadRequested();
}

/// Read the first page again, and show it in place of every page loaded. The
/// rows stay while it runs, and stay when it fails.
final class NotificationListRefreshRequested extends NotificationListEvent {
  const NotificationListRefreshRequested();
}

/// Read the page after the last one loaded, and add it below.
final class NotificationListMoreRequested extends NotificationListEvent {
  const NotificationListMoreRequested();
}

/// The user opened the notification [id]: it is marked read.
final class NotificationListOpened extends NotificationListEvent {
  const NotificationListOpened(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

/// Mark every notification the user holds read, loaded or not.
final class NotificationListAllMarkedRead extends NotificationListEvent {
  const NotificationListAllMarkedRead();
}
