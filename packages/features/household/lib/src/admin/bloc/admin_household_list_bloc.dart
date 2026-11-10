import 'dart:async';
import 'dart:math' as math;

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/src/admin/bloc/admin_household_list_event.dart';
import 'package:household/src/admin/bloc/admin_household_list_state.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Drives the staff households list (#685): every household on the server,
/// searched, filtered by status and sorted, a page at a time, and the
/// restore of a deleted one.
///
/// Nothing is cached (#683). The list is read when the screen opens, on each
/// query change, and when it comes back into view.
///
/// ## Queries
///
/// A status or sort change reads at once, from the spinner: the rows shown
/// were another query's. A search reads once typing pauses for
/// [searchDelay]. Each state carries the query its content answers, so a
/// search's text reaches the state when its read starts, not as it is typed.
/// A change that leaves what the server is asked the same, such as a space
/// typed after a word, reads nothing (see [AdminHouseholdQuery.readsAs]).
///
/// A keystroke that asks the server something new drops every read out for
/// the older search, first page or more, so none lands under the newer
/// text, over the spinner or over rows. The rows shown, or the spinner, stay
/// through the pause, and the older search reads nothing more meanwhile: a
/// load more asked for is dropped, and a read the list shown would take, as
/// after a restore, is put off. If the person types back to the search shown
/// before the pause ends, the list is read again when a read of its first
/// page was dropped or put off, or a load more was asked for in the pause,
/// as the list asks for its own after restores empty it. A status or sort
/// change in the pause reads with the text as typed.
///
/// The recently deleted order needs deleted rows: a switch to Live falls back
/// to the name order, and that order is never sent under Live.
///
/// Each read of the first page starts a generation. An answer from an older
/// one, first page or later, is dropped, so the rows are always the latest
/// read's, whichever answers first.
///
/// ## Pages
///
/// Load more asks for the page after the pages read. Reading the list shown
/// again, as when it comes back into view or after a restore, reads as many
/// pages as were read, so the rows a person scrolled to, and the one they
/// opened, are still there (see [_read]).
///
/// A restore that takes a
/// row out of the server's order, as under Deleted, moves the rows after it
/// up one. Load more then asks for the page that now holds the first row not
/// shown, and drops the rows it already shows. One asked for while the first
/// page is being read again waits for that read, and goes with it if it
/// fails. A list that restores empty while the server has more reads on.
///
/// ## Restore
///
/// Restores run per household, apart from the reads, and one still running
/// when the query changes settles against the rows shown then. A restored
/// row leaves the list under Deleted, and turns live in place under All;
/// under All by recently deleted, where it moves after every deleted row,
/// the list is then read again to put it there. A 409 says the household is
/// live already, which is done. A 404 says there
/// is nothing this caller may restore, and the row stays. After either, the
/// list is read again.
///
/// A restore that is done also reads the list again when the rows shown may
/// not have heard of it: a read is out that the server may answer as it was
/// before, the rows were read since it began, or a page read since may have
/// skipped a row it moved.
///
/// ## Refusals
///
/// A refused read, load more or restore is [AdminHouseholdListRefused], and
/// asks the caller's access again: the refusal is the server's word that the
/// answer the client holds may be out of date. It ends every read out, whose
/// answer was asked under the access the server has just refused.
class AdminHouseholdListBloc
    extends Bloc<AdminHouseholdListEvent, AdminHouseholdListState> {
  AdminHouseholdListBloc({
    required this._remote,
    this._access,
    this.searchDelay = const Duration(milliseconds: 300),
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.admin.list'),
       super(const AdminHouseholdListLoading()) {
    on<AdminHouseholdListLoadRequested>(_onLoadRequested);
    on<AdminHouseholdListMoreRequested>(_onMoreRequested);
    on<AdminHouseholdListSearchChanged>(
      _onSearchChanged,
      transformer: restartable(),
    );
    on<AdminHouseholdListSearchSettled>(_onSearchSettled);
    on<AdminHouseholdListStatusChanged>(_onStatusChanged);
    on<AdminHouseholdListSortChanged>(_onSortChanged);
    on<AdminHouseholdListRestoreRequested>(_onRestoreRequested);
    on<AdminHouseholdListOutcomeDismissed>(_onOutcomeDismissed);
  }

  /// How long typing must pause before a search is read.
  final Duration searchDelay;

  final AdminHouseholdRemoteDataSource _remote;
  final CallerAccessRepository? _access;
  final BgeLogger _logger;

  static const int _pageSize = AdminHouseholdRemoteDataSource.pageSize;

  /// The query the rows, or the read for them, answer.
  AdminHouseholdQuery _query = const AdminHouseholdQuery();

  /// The rows on screen. Null until a read succeeds, and again after the
  /// query changes or a read fails or is refused.
  List<AdminHouseholdRow>? _rows;

  /// Whether the server has rows past the pages read.
  bool _hasMore = false;

  /// Where the next page starts in the server's order: past the pages read,
  /// less one for each restore that took a row shown out of that order.
  int _offset = 0;

  /// Whether a load more is out.
  bool _loadingMore = false;

  /// A load more was asked for while the first page was being read again,
  /// and is asked for once that read has answered.
  bool _moreWaiting = false;

  bool _loadMoreFailed = false;

  /// How many load mores have asked the server.
  int _moresAsked = 0;

  /// The latest read of the first page. Older ones that answer late are
  /// dropped, as are load mores asked under them.
  int _generation = 0;

  /// The latest generation whose read has answered. Behind [_generation]
  /// while its read is out.
  int _answered = 0;

  bool get _reading => _answered != _generation;

  /// Ids of the households with a restore in flight.
  final Set<String> _restoring = {};

  /// What the last restore answered, until dismissed or replaced.
  AdminHouseholdRestoreOutcome? _outcome;

  /// The search field's text as last typed. Ahead of [_query]'s while a
  /// search waits out its pause.
  String _typed = '';

  /// Whether the text typed asks the server something the list shown does
  /// not. A search then waits out its pause, and reads anew when it ends.
  bool get _searchPending => !_query.copyWith(text: _typed).readsAs(_query);

  /// The list shown is owed a read: one was dropped, or put off, or a load
  /// more was asked for, while a search typed since waited out its pause.
  /// Asked if the person types back to the search shown.
  bool _owed = false;

  Future<void> _onLoadRequested(
    AdminHouseholdListLoadRequested event,
    Emitter<AdminHouseholdListState> emit,
  ) async {
    // The search waiting out its pause reads anew when it ends. A read of
    // the older search now could only land its rows under the newer text.
    if (_searchPending) {
      _owed = true;
      return;
    }
    await _reload(emit);
  }

  /// Reads the list shown again, as far as the pages read reach. Rows shown
  /// stay until the read answers.
  Future<void> _reload(Emitter<AdminHouseholdListState> emit) async {
    if (_rows == null) {
      emit(AdminHouseholdListLoading(query: _query));
      await _read(emit);
    } else {
      _emitReady(emit);
      // Whole pages: a restore that moved the rows up leaves _offset short
      // of one.
      final pages = (_offset / _pageSize).ceil();
      await _read(emit, extent: pages < 1 ? _pageSize : pages * _pageSize);
    }
  }

  Future<void> _onSearchChanged(
    AdminHouseholdListSearchChanged event,
    Emitter<AdminHouseholdListState> emit,
  ) async {
    _typed = event.text;
    if (_searchPending) _leaveForSearch(emit);
    await Future<void>.delayed(searchDelay);
    // Typing went on during the pause; the newer text waits out its own.
    if (emit.isDone || isClosed) return;
    // Read in a handler of its own: the next keystroke cancels this one, and
    // must not cut short the read it starts when that keystroke asks the
    // same.
    add(AdminHouseholdListSearchSettled(event.text));
  }

  /// Ends what the list shown has out, as a search that asks something new
  /// starts its pause: nothing the older search asked for may land under the
  /// newer text, whether over the spinner or over rows. The rows shown stay
  /// until the new search's read starts.
  void _leaveForSearch(Emitter<AdminHouseholdListState> emit) {
    if (_reading) _owed = true;
    if (_reading || _loadingMore) {
      _generation++;
      _answered = _generation;
      _loadingMore = false;
      _moreWaiting = false;
    }
    // The banner told of the rows the older search found. A restore that
    // ends from here on reports, and its banner stays with the new rows.
    _outcome = null;
    _emitReady(emit);
  }

  Future<void> _onSearchSettled(
    AdminHouseholdListSearchSettled event,
    Emitter<AdminHouseholdListState> emit,
  ) =>
      // Its keystroke cleared the banner already; one shown since is news.
      _change(_query.copyWith(text: event.text), emit, keepOutcome: true);

  Future<void> _onStatusChanged(
    AdminHouseholdListStatusChanged event,
    Emitter<AdminHouseholdListState> emit,
  ) {
    final status = event.status;
    final sort = _query.sort.allowedWith(status)
        ? _query.sort
        : AdminHouseholdSort.name;
    // With the text as typed, so a search still waiting out its pause is
    // read now, not on its own after.
    return _change(
      _query.copyWith(status: status, sort: sort, text: _typed),
      emit,
    );
  }

  Future<void> _onSortChanged(
    AdminHouseholdListSortChanged event,
    Emitter<AdminHouseholdListState> emit,
  ) async {
    // The server refuses the recently deleted order under Live.
    if (!event.sort.allowedWith(_query.status)) return;
    await _change(_query.copyWith(sort: event.sort, text: _typed), emit);
  }

  /// Shows the list under [next], reading it unless the server would be
  /// asked the same as for the rows shown or being read, and nothing is
  /// owed.
  Future<void> _change(
    AdminHouseholdQuery next,
    Emitter<AdminHouseholdListState> emit, {
    bool keepOutcome = false,
  }) async {
    final asked = _generation > 0;
    if (asked && next.readsAs(_query)) {
      final changed = next != _query;
      _query = next;
      // Typed back to the search shown after its read was dropped.
      if (_owed) {
        await _reload(emit);
      } else if (changed) {
        _showUnderQuery(emit);
      }
      return;
    }

    // The rows shown, and the banner about them, were another query's. A
    // restore still in flight reports when it ends.
    _query = next;
    _rows = null;
    _moreWaiting = false;
    if (!keepOutcome) _outcome = null;
    emit(AdminHouseholdListLoading(query: next));
    await _read(emit);
  }

  /// Shows the state shown now, under [_query].
  void _showUnderQuery(Emitter<AdminHouseholdListState> emit) {
    switch (state) {
      case AdminHouseholdListReady():
        _emitReady(emit);
      case AdminHouseholdListLoading():
        emit(AdminHouseholdListLoading(query: _query));
      case AdminHouseholdListRefused():
        emit(AdminHouseholdListRefused(query: _query));
      case AdminHouseholdListFailed():
        emit(AdminHouseholdListFailed(query: _query));
    }
  }

  /// Reads the first [extent] rows under [_query], a whole number of pages,
  /// in a new generation.
  ///
  /// Up to [AdminHouseholdRemoteDataSource.maxPageSize] rows is one request.
  /// Past it, requests of that many rows each, so the last can read more
  /// than [extent]. A row a later request answers again, as when the
  /// server's rows moved down between them, is dropped.
  Future<void> _read(
    Emitter<AdminHouseholdListState> emit, {
    int extent = _pageSize,
  }) async {
    assert(extent > 0 && extent % _pageSize == 0, 'whole pages only');
    final read = ++_generation;
    _owed = false;
    // A load more out answers for rows this read replaces. It is dropped
    // when it lands.
    _loadingMore = false;
    final query = _query;
    // A multiple of the page size either way, so load more's page after it
    // starts where this read ends.
    final limit = math.min(extent, AdminHouseholdRemoteDataSource.maxPageSize);
    try {
      final rows = <AdminHouseholdRow>[];
      final ids = <String>{};
      var pages = 0;
      var hasMore = true;
      while (hasMore && pages * limit < extent) {
        final page = await _remote.fetchPage(
          status: query.status,
          query: query.sentQuery,
          sort: query.sort,
          page: ++pages,
          limit: limit,
        );
        // Nobody is left to show the pages after it to.
        if (read != _generation || isClosed) return;
        rows.addAll(page.items.where((row) => ids.add(row.id)));
        hasMore = page.meta.hasMore;
      }
      _rows = rows;
      _hasMore = hasMore;
      _offset = pages * limit;
      _loadMoreFailed = false;
      if (!_hasMore) _moreWaiting = false;
      _emitReady(emit);
      if (_moreWaiting && !isClosed) {
        add(const AdminHouseholdListMoreRequested());
      }
    } on AdminHouseholdForbiddenException {
      // Asked even when a newer read superseded this one: the refusal is
      // about the caller, not the rows.
      unawaited(_access?.refresh());
      if (read != _generation) return;
      _refuse(emit);
    } on Object catch (error, stackTrace) {
      if (read != _generation) return;
      _logger.warn(
        'Staff households read failed',
        error: error,
        stackTrace: stackTrace,
      );
      _forgetRows();
      emit(AdminHouseholdListFailed(query: _query));
    } finally {
      if (read == _generation) _answered = read;
    }
  }

  Future<void> _onMoreRequested(
    AdminHouseholdListMoreRequested event,
    Emitter<AdminHouseholdListState> emit,
  ) async {
    final shown = _rows;
    if (shown == null || !_hasMore || _loadingMore) return;
    // The rows shown go when the search waiting out its pause is read. If
    // the person types back to them instead, they are read again: this may
    // be the list's own read on, after restores emptied it.
    if (_searchPending) {
      _owed = true;
      return;
    }
    if (_reading) {
      // The read out replaces the rows this page would follow.
      if (!_moreWaiting) {
        _moreWaiting = true;
        _emitReady(emit);
      }
      return;
    }

    _moreWaiting = false;
    final read = _generation;
    final query = _query;
    final page = _offset ~/ _pageSize + 1;
    _loadingMore = true;
    _loadMoreFailed = false;
    _moresAsked++;
    _emitReady(emit);
    try {
      final result = await _remote.fetchPage(
        status: query.status,
        query: query.sentQuery,
        sort: query.sort,
        page: page,
      );
      final current = _rows;
      if (read != _generation || current == null) return;
      // The page can start among the rows shown, after a restore moved the
      // server's rows up. A row shown when this was asked for and restored
      // away since was read before the restore, and must not come back.
      final known = {
        for (final row in [...shown, ...current]) row.id,
      };
      _rows = [
        ...current,
        for (final row in result.items)
          if (!known.contains(row.id)) row,
      ];
      _offset = page * _pageSize;
      _hasMore = result.meta.hasMore;
    } on AdminHouseholdForbiddenException {
      unawaited(_access?.refresh());
      if (read != _generation) return;
      _refuse(emit);
      return;
    } on Object catch (error, stackTrace) {
      if (read != _generation) return;
      _logger.warn(
        'Staff households page $page failed',
        error: error,
        stackTrace: stackTrace,
      );
      _loadMoreFailed = true;
    }
    _loadingMore = false;
    _emitReady(emit);
  }

  Future<void> _onRestoreRequested(
    AdminHouseholdListRestoreRequested event,
    Emitter<AdminHouseholdListState> emit,
  ) async {
    final id = event.id;
    final row = _rows?.where((r) => r.id == id).firstOrNull;
    if (row == null || !row.isDeleted || _restoring.contains(id)) return;

    _restoring.add(id);
    _outcome = null;
    _emitReady(emit);
    final since = (
      generation: _generation,
      // A load more already out counts as asked after: the server may read
      // its page after the restore.
      mores: _loadingMore ? _moresAsked - 1 : _moresAsked,
    );

    final ended = await _restore(id);
    _restoring.remove(id);

    final AdminHouseholdRestoreResult result;
    final bool readAgain;
    switch (ended) {
      case _Restore.refused:
        _refuse(emit);
        return;
      case _Restore.done:
        result = AdminHouseholdRestoreResult.restored;
        readAgain = _settleRestored(id, since);
      case _Restore.alreadyLive:
        // Someone else restored it first, so the list may have moved on too.
        result = AdminHouseholdRestoreResult.restored;
        _settleRestored(id, since);
        readAgain = true;
      case _Restore.notRestorable:
        // The row stays until the read answers.
        result = AdminHouseholdRestoreResult.notRestorable;
        readAgain = true;
      case _Restore.failed:
        result = AdminHouseholdRestoreResult.failed;
        readAgain = false;
    }
    _outcome = AdminHouseholdRestoreOutcome(result: result, name: row.name);
    _emitReady(emit);

    // Nothing to correct while the list is down: the next read is the
    // person's.
    final rows = _rows;
    if (isClosed || (rows == null && !_reading)) return;
    if (readAgain) {
      add(const AdminHouseholdListLoadRequested());
    } else if (rows != null && rows.isEmpty && _hasMore) {
      add(const AdminHouseholdListMoreRequested());
    }
  }

  /// Settles a restore of [id], begun at [since], that left the household
  /// live, against the rows as they are now: a read or another restore may
  /// have landed. Answers whether the list is to be read again.
  bool _settleRestored(String id, ({int generation, int mores}) since) {
    final rows = _rows;
    final row = rows?.where((r) => r.id == id).firstOrNull;
    var moved = false;
    // Under All by recently deleted: the row belongs after every deleted
    // row, among the live ones, which may not be shown.
    var unplaced = false;
    // A row shown live already was read after the restore.
    if (rows != null && row != null && row.isDeleted) {
      final leaves = _query.status == AdminHouseholdStatus.deleted;
      // Under All by recently deleted, live rows come after every deleted
      // one, so the restored row moves among them.
      moved = leaves || _query.sort == AdminHouseholdSort.deleted;
      unplaced = !leaves && moved;
      _rows = [
        for (final r in rows)
          if (r.id != id) r else if (!leaves) r.restored(),
      ];
      if (moved) _offset--;
    }
    return _reading ||
        _generation != since.generation ||
        (moved && _moresAsked != since.mores) ||
        unplaced;
  }

  /// Restores [id]. Answers how it ended. Never throws.
  Future<_Restore> _restore(String id) async {
    try {
      await _remote.restore(id);
      return _Restore.done;
    } on AdminHouseholdNotDeletedException {
      return _Restore.alreadyLive;
    } on AdminHouseholdNotFoundException {
      return _Restore.notRestorable;
    } on AdminHouseholdForbiddenException {
      unawaited(_access?.refresh());
      return _Restore.refused;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household restore failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _Restore.failed;
    }
  }

  void _onOutcomeDismissed(
    AdminHouseholdListOutcomeDismissed event,
    Emitter<AdminHouseholdListState> emit,
  ) {
    if (_outcome == null) return;
    _outcome = null;
    _emitReady(emit);
  }

  /// Shows [AdminHouseholdListRefused], and ends every read out.
  void _refuse(Emitter<AdminHouseholdListState> emit) {
    _generation++;
    _answered = _generation;
    _forgetRows();
    emit(AdminHouseholdListRefused(query: _query));
  }

  void _forgetRows() {
    _rows = null;
    _owed = false;
    _hasMore = false;
    _loadingMore = false;
    _moreWaiting = false;
    _loadMoreFailed = false;
  }

  /// Shows the rows, when there are rows to show.
  void _emitReady(Emitter<AdminHouseholdListState> emit) {
    final rows = _rows;
    if (rows == null) return;
    emit(
      AdminHouseholdListReady(
        query: _query,
        rows: rows,
        hasMore: _hasMore,
        loadingMore: _loadingMore || _moreWaiting,
        loadMoreFailed: _loadMoreFailed,
        restoring: {..._restoring},
        outcome: _outcome,
      ),
    );
  }
}

/// How a restore ended, before it is told as an
/// [AdminHouseholdRestoreResult].
enum _Restore {
  done,

  /// A 409: the household is live already.
  alreadyLive,
  notRestorable,
  refused,
  failed,
}
