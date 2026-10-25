import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Where an invite list stood as an action began, for
/// [InvitePages.settle].
typedef InviteActionMark = ({int mores, int clears});

/// One paged list of invites read from the server, and the reads that fill
/// it: the household's invite list and the invite inbox (#455) share it.
///
/// The DataGateway list's rules (#41). The rows live here rather than only
/// in a bloc's emitted state, so an action that ends after a reload still
/// has a row to settle. Of two overlapping reads, the one asked for last
/// wins, whichever answers first.
///
/// More asks for the page holding the first row not shown yet. That is the
/// next page until an action drops a row: the server's rows then move up,
/// and asking for the next page would skip one. Rows already shown, or
/// shown when More was asked for, are dropped from the answer. A More asked
/// for while the list is being read again waits for that read, showing as
/// loading meanwhile, rather than being lost.
///
/// An action that drops a row while a More is out can move the server's
/// rows under it: the More's page may be read after the action's write and
/// skip a row, whichever answers first. Rows past that page say nothing
/// about the gap, so the bloc reads the list again instead (see
/// [moreMark]).
///
/// An action that spans a [clear] ends over rows read after it began. The
/// server may have answered that read before the action's write, and left
/// out a row the action has since brought under the filter, so [settle]
/// asks for the list again.
class InvitePages {
  InvitePages({
    required this._fetch,
    required this._pageSize,
    required this._logger,
  });

  final Future<PaginatedResult<HouseholdInvite>> Function(int page, int limit)
  _fetch;
  final int _pageSize;
  final BgeLogger _logger;

  /// The rows on screen. Null until a read succeeds, and again after one
  /// fails or is refused.
  List<HouseholdInvite>? rows;

  /// Whether the server has more rows past the ones shown.
  bool get hasMore => _hasMore;
  bool _hasMore = false;

  /// Whether a More is in flight, or waiting for a read to end.
  bool get loadingMore => _loadingMore || moreWaiting;
  bool _loadingMore = false;

  /// A More was asked for during a read, and is to be asked for again once
  /// [load] has answered.
  bool get moreWaiting => _moreWaiting;
  bool _moreWaiting = false;

  /// The last page read.
  int _page = 0;

  /// The last More added nothing new, though the server said there was
  /// more. The next one moves past it instead of asking for it again.
  bool _stalled = false;

  /// Which read is the latest. An older one that answers late is dropped.
  int _readSequence = 0;

  /// The latest read that has answered.
  int _readAnswered = 0;

  /// Whether a read of the first page is in flight.
  bool get reading => _readAnswered != _readSequence;

  /// How many Mores have asked the server.
  int _moresAsked = 0;

  /// A mark taken as an action starts, for [moreSince].
  ///
  /// A More already in flight counts as asked after the mark: the server
  /// may read its page after the action's write.
  int get moreMark => _loadingMore ? _moresAsked - 1 : _moresAsked;

  /// Whether a More has asked the server since [mark] was taken.
  bool moreSince(int mark) => _moresAsked != mark;

  /// How many times the rows were forgotten for another filter.
  int _clears = 0;

  /// A mark taken as an action starts, for [settle].
  InviteActionMark get actionMark => (mores: moreMark, clears: _clears);

  /// Forgets the rows, for a list that starts over under another filter.
  void clear() {
    rows = null;
    _moreWaiting = false;
    _clears++;
  }

  /// Settles an action on the row [id], begun at [mark], against the rows
  /// as they are now: a reload or another row's action may have landed.
  ///
  /// [after] is the invite as the server left it, which replaces the row,
  /// or drops it when [admits] says it no longer belongs. Null for an
  /// action that failed or was refused, which says nothing about the row,
  /// so whatever is there now stays.
  ///
  /// Answers whether the list is to be read again: a read is in flight, a
  /// dropped row may have been skipped by a More, or the rows were read
  /// under a filter set after the action began.
  bool settle(
    String id,
    HouseholdInvite? after,
    InviteActionMark mark, {
    required bool Function(HouseholdInvite invite) admits,
  }) {
    final shown = rows;
    final dropped = after != null && !admits(after);
    if (shown != null && after != null) {
      rows = [
        for (final invite in shown)
          if (invite.id != id) invite else if (!dropped) after,
      ];
    }
    final skipped = dropped && moreSince(mark.mores);
    final refiltered = after != null && _clears != mark.clears;
    return reading || skipped || refiltered;
  }

  /// Reads the first page into [rows].
  ///
  /// Answers false when a later read was asked for meanwhile, whose answer
  /// stands instead. Throws what the read threw, leaving [rows] null, unless
  /// a later read was asked for.
  Future<bool> load() async {
    final read = ++_readSequence;
    // A More in flight answers for rows this read replaces; it is dropped
    // when it lands.
    _loadingMore = false;
    try {
      final result = await _fetch(1, _pageSize);
      if (read != _readSequence) return false;
      rows = result.items;
      _page = 1;
      _hasMore = result.meta.hasMore;
      _stalled = false;
      if (!_hasMore) _moreWaiting = false;
      return true;
    } on Object {
      if (read != _readSequence) return false;
      clear();
      rethrow;
    } finally {
      if (read == _readSequence) _readAnswered = read;
    }
  }

  /// Reads the next page into [rows], calling [changed] whenever there is
  /// something new to show: as it starts and as it ends. A failure leaves
  /// the rows shown, which are still right, for More to be tried again.
  Future<void> more(void Function() changed) async {
    final shown = rows;
    if (shown == null || !_hasMore || _loadingMore) return;
    if (reading) {
      if (!_moreWaiting) {
        _moreWaiting = true;
        changed();
      }
      return;
    }

    _moreWaiting = false;
    final read = _readSequence;
    final page = _stalled ? _page + 1 : shown.length ~/ _pageSize + 1;
    _loadingMore = true;
    _moresAsked++;
    changed();
    try {
      final result = await _fetch(page, _pageSize);
      if (read != _readSequence) return;
      final current = rows ?? const <HouseholdInvite>[];
      // A row shown when More was asked for and gone now was settled
      // meanwhile; this answer was read before that, so it must not bring
      // the row back.
      final known = {
        for (final invite in [...shown, ...current]) invite.id,
      };
      final fresh = [
        for (final invite in result.items)
          if (!known.contains(invite.id)) invite,
      ];
      rows = [...current, ...fresh];
      _page = page;
      _hasMore = result.meta.hasMore;
      _stalled = fresh.isEmpty && _hasMore;
    } on Object catch (error, stackTrace) {
      if (read != _readSequence) return;
      _logger.warn(
        'Invite page $page failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _loadingMore = false;
    changed();
  }
}
