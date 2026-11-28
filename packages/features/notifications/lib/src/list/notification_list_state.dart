import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the read of the first page stands (#475).
enum NotificationListStatus { loading, loaded, loadFailed }

/// Why a read or a write failed (#475).
enum NotificationListFailure {
  /// No answer that says anything: offline, a timeout, a 5xx, or a session
  /// a retry may restore. Trying again later may work.
  transient,

  /// The server refused it, and sending it again will not change that.
  permanent,
}

/// What a read or a write that failed while the rows were showing answered,
/// for the page to say (#475).
///
/// Each one is new: two outcomes are never equal, even for the same failure,
/// so a page that shows each new outcome shows a repeat too.
sealed class NotificationListOutcome extends Equatable {
  NotificationListOutcome(this.failure);

  final NotificationListFailure failure;

  /// What makes this outcome unlike any other.
  final Object _identity = Object();

  @override
  List<Object?> get props => [failure, _identity];
}

/// Marking every notification read failed. The rows are as they were.
final class MarkAllFailed extends NotificationListOutcome {
  MarkAllFailed(super.failure);
}

/// Reading the first page again failed. The rows loaded stay.
final class RefreshFailed extends NotificationListOutcome {
  RefreshFailed(super.failure);
}

/// Reading the next page failed. The rows loaded stay, and the same page can
/// be asked for again.
final class LoadMoreFailed extends NotificationListOutcome {
  LoadMoreFailed(super.failure);
}

/// The user's notifications, read ones included, newest first (#475).
final class NotificationListState extends Equatable {
  const NotificationListState({
    this.status = NotificationListStatus.loading,
    this.items = const [],
    this.nextCursor,
    this.failure,
    this.refreshing = false,
    this.loadingMore = false,
    this.markingAll = false,
    this.outcome,
  });

  final NotificationListStatus status;

  /// The rows loaded so far, each id once.
  final List<UserNotification> items;

  /// The opaque cursor for the page after [items], or null when there is
  /// none.
  final String? nextCursor;

  /// Why the first page couldn't be read, while [status] is
  /// [NotificationListStatus.loadFailed]; null otherwise.
  final NotificationListFailure? failure;

  /// Whether the first page is being read again over the rows.
  final bool refreshing;

  /// Whether the page after [items] is being read.
  final bool loadingMore;

  /// Whether marking every notification read is on its way.
  final bool markingAll;

  /// What the last failure while the rows were showing answered. It is
  /// carried by the state it came with alone: the next state drops it.
  final NotificationListOutcome? outcome;

  /// Whether a page follows [items].
  bool get hasMore => nextCursor != null;

  /// Whether any row loaded is unread.
  bool get hasUnread => items.any((item) => !item.read);

  /// A copy with the fields given, and no [outcome] unless one is given.
  /// [nextCursor] and [failure] take a function, so that a copy can set them
  /// to null.
  NotificationListState copyWith({
    NotificationListStatus? status,
    List<UserNotification>? items,
    String? Function()? nextCursor,
    NotificationListFailure? Function()? failure,
    bool? refreshing,
    bool? loadingMore,
    bool? markingAll,
    NotificationListOutcome? outcome,
  }) => NotificationListState(
    status: status ?? this.status,
    items: items ?? this.items,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    failure: failure == null ? this.failure : failure(),
    refreshing: refreshing ?? this.refreshing,
    loadingMore: loadingMore ?? this.loadingMore,
    markingAll: markingAll ?? this.markingAll,
    outcome: outcome,
  );

  @override
  List<Object?> get props => [
    status,
    items,
    nextCursor,
    failure,
    refreshing,
    loadingMore,
    markingAll,
    outcome,
  ];
}
