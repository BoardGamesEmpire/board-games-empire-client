import 'package:bloc/bloc.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter/foundation.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:notifications/src/list/notification_list_event.dart';
import 'package:notifications/src/list/notification_list_state.dart';

/// Pages through the user's notifications, read ones included (#475), and
/// marks them read: one when it is opened, or all at once.
///
/// ## Reading
///
/// Load and refresh both read the first page. A refresh shows it in place of
/// every page loaded, cursor included, so a notification written while the
/// user paged down shows at the head. More reads the page after the last
/// one, with the cursor exactly as the server gave it, and adds its rows
/// below; a row already shown keeps its place, so a page that overlaps the
/// last never lists a row twice.
///
/// A load or refresh asked for while another runs takes its place, and the
/// earlier one's answer is dropped. A More asked for while one is out, while
/// refreshing, or with no page after the last, is ignored. A More that
/// answers after a load or refresh started belongs to the listing that read
/// replaces, and adds nothing.
///
/// A failed load is [NotificationListStatus.loadFailed]. A failed refresh or
/// More keeps the rows and the cursor, so More can be asked for again, and
/// says so in [NotificationListState.outcome].
///
/// ## Marking read
///
/// Opening an unread row shows it read at once and sends it, without waiting
/// for a row opened before it to be sent. When that fails, the row still
/// shows read and nothing is said: the next refresh tells the truth.
/// `onMarkedRead` hears of each one the server took.
///
/// Marking all read shows every row read at once. When it fails, the rows it
/// changed are as they were, and the outcome says so. `onAllMarkedRead`
/// hears when the server took it. A row opened meanwhile is sent on its
/// own, and stays read whatever marking all answers.
///
/// A read that was out while marking all read was may have been answered
/// before the server marked them, so its unread rows show read too: at once
/// while marking all read is out, going back with the rest when it fails,
/// or for good when the server took it.
///
/// The callbacks are how the unread count hears, and this bloc never reads
/// the count itself.
class NotificationListBloc
    extends Bloc<NotificationListEvent, NotificationListState> {
  NotificationListBloc(
    this._remote, {
    this._pageSize = NotificationRemoteDataSource.defaultPageSize,
    this._onMarkedRead,
    this._onAllMarkedRead,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       super(const NotificationListState()) {
    on<NotificationListLoadRequested>(_onLoad, transformer: restartable());
    on<NotificationListRefreshRequested>(
      _onRefresh,
      transformer: restartable(),
    );
    on<NotificationListMoreRequested>(_onMore, transformer: droppable());
    // Concurrent, not sequential (#475): a row's local read must not wait
    // behind an earlier row's hanging markRead. It runs before any await,
    // so a second open of the same row finds it read.
    on<NotificationListOpened>(_onOpened, transformer: concurrent());
    on<NotificationListAllMarkedRead>(
      _onAllMarked,
      transformer: droppable(),
    );
  }

  final NotificationRemoteDataSource _remote;
  final int _pageSize;
  final void Function(int count)? _onMarkedRead;
  final VoidCallback? _onAllMarkedRead;

  /// When a row marked read was read.
  final DateTime Function() _now;

  /// Counts the reads of the first page, so an answer can tell a later read
  /// has replaced its listing.
  int _listing = 0;

  /// While marking all read is out: each row it showed read, by id, as it
  /// was before. A row opened meanwhile leaves it.
  Map<String, UserNotification>? _unreadBeforeAll;

  /// When marking all read, while it is out, showed its rows read.
  DateTime? _markingAllAt;

  /// How many times marking all read was sent, so that a read can tell
  /// whether one was out while it was.
  int _marksAllSent = 0;

  /// The last sending of marking all read the server took, numbered as
  /// [_marksAllSent] counts them, and when it showed its rows read; null
  /// until one is taken.
  ({int sent, DateTime at})? _markAllTaken;

  Future<void> _onLoad(
    NotificationListLoadRequested event,
    Emitter<NotificationListState> emit,
  ) => _load(emit);

  Future<void> _load(Emitter<NotificationListState> emit) async {
    final listing = ++_listing;
    final since = _marksAllSince();
    // A bloc's first emit is not compared with its initial state, so the
    // spinner it starts on is not emitted again.
    if (state != const NotificationListState()) {
      emit(const NotificationListState());
    }
    try {
      final page = await _remote.fetchPage(limit: _pageSize);
      if (listing != _listing) return;
      emit(_firstPage(page, since));
    } on Object catch (error) {
      if (listing == _listing) {
        emit(
          state.copyWith(
            status: NotificationListStatus.loadFailed,
            failure: () => _failureOf(error),
          ),
        );
      }
      if (error is! NotificationRemoteException) rethrow;
    }
  }

  Future<void> _onRefresh(
    NotificationListRefreshRequested event,
    Emitter<NotificationListState> emit,
  ) async {
    if (state.status != NotificationListStatus.loaded) {
      return _load(emit);
    }
    final listing = ++_listing;
    final since = _marksAllSince();
    emit(state.copyWith(refreshing: true));
    try {
      final page = await _remote.fetchPage(limit: _pageSize);
      if (listing != _listing) return;
      emit(_firstPage(page, since));
    } on Object catch (error) {
      if (listing == _listing) {
        emit(
          state.copyWith(
            refreshing: false,
            outcome: RefreshFailed(_failureOf(error)),
          ),
        );
      }
      if (error is! NotificationRemoteException) rethrow;
    }
  }

  /// The state once [page] is the first page, from a read sent when
  /// [_marksAllSince] gave [since]: it replaces every row and the cursor. A
  /// More or marking all read still out stays so.
  NotificationListState _firstPage(NotificationPage page, int since) =>
      state.copyWith(
        status: NotificationListStatus.loaded,
        items: _distinct(_underMarkAll(page.items, since)),
        nextCursor: () => page.nextCursor,
        failure: () => null,
        refreshing: false,
      );

  Future<void> _onMore(
    NotificationListMoreRequested event,
    Emitter<NotificationListState> emit,
  ) async {
    final cursor = state.nextCursor;
    if (state.status != NotificationListStatus.loaded ||
        cursor == null ||
        state.refreshing) {
      return;
    }
    final listing = _listing;
    final since = _marksAllSince();
    emit(state.copyWith(loadingMore: true));
    try {
      final page = await _remote.fetchPage(cursor: cursor, limit: _pageSize);
      if (listing != _listing) {
        // Its listing was replaced: the page belongs to the old one.
        emit(state.copyWith(loadingMore: false));
        return;
      }
      emit(
        state.copyWith(
          items: _distinct([
            ...state.items,
            ..._underMarkAll(page.items, since),
          ]),
          nextCursor: () => page.nextCursor,
          loadingMore: false,
        ),
      );
    } on Object catch (error) {
      emit(
        state.copyWith(
          loadingMore: false,
          outcome: listing == _listing
              ? LoadMoreFailed(_failureOf(error))
              : null,
        ),
      );
      if (error is! NotificationRemoteException) rethrow;
    }
  }

  Future<void> _onOpened(
    NotificationListOpened event,
    Emitter<NotificationListState> emit,
  ) async {
    final items = state.items;
    final index = items.indexWhere((item) => item.id == event.id);
    if (index < 0) return;
    final row = items[index];
    // A row marking all read showed read is sent on its own all the same,
    // and leaves what that restores if it fails.
    final readByAll = _unreadBeforeAll?.remove(event.id) != null;
    if (row.read && !readByAll) return;
    if (!row.read) {
      emit(
        state.copyWith(
          items: [...items]..[index] = row.markedRead(_now()),
        ),
      );
    }
    try {
      await _remote.markRead([event.id]);
    } on NotificationRemoteException {
      // The row stays read, and the next refresh tells the truth.
      return;
    }
    _onMarkedRead?.call(1);
  }

  Future<void> _onAllMarked(
    NotificationListAllMarkedRead event,
    Emitter<NotificationListState> emit,
  ) async {
    final at = _markingAllAt = _now();
    _marksAllSent++;
    final before = _unreadBeforeAll = {
      for (final item in state.items)
        if (!item.read) item.id: item,
    };
    emit(
      state.copyWith(
        markingAll: true,
        items: [
          for (final item in state.items)
            if (item.read) item else item.markedRead(at),
        ],
      ),
    );
    try {
      await _remote.markAllRead();
    } on Object catch (error) {
      _unreadBeforeAll = null;
      _markingAllAt = null;
      emit(
        state.copyWith(
          markingAll: false,
          items: [
            for (final item in state.items)
              // A row this changed goes back. One a read since replaced, or
              // one opened meanwhile, stays as it is.
              if (before[item.id] case final original?
                  when item == original.markedRead(at))
                original
              else
                item,
          ],
          outcome: MarkAllFailed(_failureOf(error)),
        ),
      );
      if (error is! NotificationRemoteException) rethrow;
      return;
    }
    _unreadBeforeAll = null;
    _markingAllAt = null;
    _markAllTaken = (sent: _marksAllSent, at: at);
    emit(state.copyWith(markingAll: false));
    _onAllMarkedRead?.call();
  }

  /// For a read sent now: the first sending of marking all read that can
  /// have been out while it was, numbered as [_marksAllSent] counts them.
  int _marksAllSince() =>
      _unreadBeforeAll != null ? _marksAllSent : _marksAllSent + 1;

  /// [rows] from a read sent when [_marksAllSince] gave [since], with what
  /// marking all read that was out meanwhile shows: unread rows read.
  ///
  /// The server may have answered the read before it marked them, so the
  /// rows may be unread on the page alone. While marking all read is out,
  /// each row this shows read joins what a failure puts back.
  List<UserNotification> _underMarkAll(
    List<UserNotification> rows,
    int since,
  ) {
    final before = _unreadBeforeAll;
    final taken = _markAllTaken;
    final DateTime at;
    if (before != null) {
      at = _markingAllAt!;
    } else if (taken != null && taken.sent >= since) {
      at = taken.at;
    } else {
      return rows;
    }
    final shown = <UserNotification>[];
    for (final row in rows) {
      if (row.read) {
        shown.add(row);
      } else {
        before?[row.id] = row;
        shown.add(row.markedRead(at));
      }
    }
    return shown;
  }

  /// Transient for a [NotificationTransientException]; permanent for anything
  /// else, which a retry won't fix.
  static NotificationListFailure _failureOf(Object error) =>
      error is NotificationTransientException
      ? NotificationListFailure.transient
      : NotificationListFailure.permanent;

  /// [items] with each id once, at its first place.
  static List<UserNotification> _distinct(List<UserNotification> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(item.id)) item,
    ];
  }
}
