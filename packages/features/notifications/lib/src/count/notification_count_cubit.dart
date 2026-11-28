import 'dart:async';
import 'dart:math' as math;

import 'package:bloc/bloc.dart';
import 'package:network_interface/network_interface.dart';

import 'package:notifications/src/count/notification_count_state.dart';

/// Keeps the unread count the bell shows (#475).
///
/// One per session: the host that owns it is rebuilt for a new server or a
/// new sign-in, so a count never carries across.
class NotificationCountCubit extends Cubit<NotificationCountState> {
  NotificationCountCubit(this._remote) : super(const NotificationCountState());

  final NotificationRemoteDataSource _remote;

  /// Which refresh is the latest. A refresh that finds it has moved on was
  /// superseded, and drops its result.
  int _generation = 0;

  /// Reads the count from the server.
  ///
  /// A refresh that starts while another is in flight replaces it: the
  /// earlier one's result is dropped. A failed refresh keeps the last count.
  Future<void> refresh() async {
    final generation = ++_generation;
    emit(state.copyWith(refreshing: true));
    try {
      final count = await _remote.fetchUnreadCount();
      if (_superseded(generation)) {
        return;
      }
      emit(NotificationCountState(unread: count));
    } on NotificationRemoteException {
      if (_superseded(generation)) {
        return;
      }
      emit(state.copyWith(refreshing: false));
    } on Object {
      // Not a failure the remote names: let it surface, but do not leave
      // the bell reading "refreshing" for ever.
      if (!_superseded(generation)) {
        emit(state.copyWith(refreshing: false));
      }
      rethrow;
    }
  }

  /// [count] notifications were marked read: the count drops by [count] at
  /// once, never below zero, and an unknown count stays unknown. Then it is
  /// read again, as [refresh] does.
  ///
  /// The read again is the truth: the server skips a notification already
  /// read, perhaps on another device, and says nothing of it, so the count it
  /// holds may not have dropped by [count]. A refresh still in flight read
  /// the count before this, so it is dropped, and the read again takes its
  /// place.
  void markedRead(int count) {
    final unread = state.unread;
    if (unread != null) {
      emit(state.copyWith(unread: math.max(0, unread - count)));
    }
    unawaited(refresh());
  }

  /// Every notification was marked read: the count is zero at once. Then it
  /// is read again, as [refresh] does, which drops a refresh still in flight
  /// and counts any that arrived since.
  void allMarkedRead() {
    emit(state.copyWith(unread: 0));
    unawaited(refresh());
  }

  bool _superseded(int generation) => isClosed || generation != _generation;
}
