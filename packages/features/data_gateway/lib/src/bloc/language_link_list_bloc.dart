import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../access/data_gateway_access.dart';
import 'language_link_list_event.dart';
import 'language_link_list_state.dart';

/// Drives a DataGateway's language worklist (#457): its language links, a
/// page at a time under a status filter, and the link, ignore and accept
/// actions that settle them.
///
/// Nothing is cached (#41). The list is read whenever the screen opens and
/// whenever the user comes back to it.
///
/// ## The filter
///
/// [LanguageLinkFilter.waiting] names no status, so the server's own default
/// applies: the links waiting on a review, pending and unresolved. Ignored and
/// resolved each ask for that status. The server orders the links by value
/// and offers no other order, so the list has no sort of its own.
///
/// Changing the filter starts the list over, from the spinner. The last
/// outcome goes too, since it described the rows just left. Choosing the
/// filter already shown does nothing.
///
/// ## Pages
///
/// A read asks for the first page. Its answer replaces every row shown,
/// however many pages there were, and says whether there is more. A read over
/// rows on screen keeps showing them until it answers, rather than going back
/// to the spinner.
///
/// More asks for the page holding the first link not read yet. The bloc keeps
/// count of how far down the server's list it has read. A read sets the count
/// to the links on its page, and each More sets it to the end of the page it
/// read. Each row an action takes off the list takes one off the count,
/// because the server's later links each move up a place. More asks for the
/// count divided by the page size, plus one, and drops from its answer the
/// links already shown, by id, so none shows twice.
///
/// A lost answer keeps its row, but the server may have made the change. When
/// that change would take the link out of the filter, the count loses one all
/// the same. Counting a place short is the safe side: the next page then
/// starts with a link already shown, which More drops, where a place too many
/// would skip the link that moved up. The same action tried again and made
/// then takes the row off, and its place, a second time. The count stops at
/// none: below a page short of it, More would ask for page 0, which the
/// server refuses every time.
///
/// The count is of places read, not rows shown, so a link added ahead of the
/// rows can't stall More. Such a link, as a language job adds a few minutes
/// after an interview, pushes every row shown down a place. The next page then
/// starts with a link already shown, and adds one fewer than it read. Asked
/// for by rows shown, More would ask for that same page again, and add nothing
/// every time after.
///
/// More and an action can't overlap: if the server had made the action's change
/// before it read More's page, the link that moved up a place would be on no
/// page read, and shown nowhere. Nor is either dropped, since each control stays
/// enabled through the other (#607) and the user would see nothing happen. So:
///
/// - More asked for during an action or a read waits, showing as loading, and
///   starts when nothing is left running. A read that says there is no more
///   ends the wait.
/// - An action asked for while More is out starts at once. More's answer is
///   dropped when it lands, and More waits for the action, still showing as
///   loading.
///
/// A read or a filter change while More is out drops More's answer when it
/// lands, and More stops showing as loading at once. A filter change ends a wait
/// too. A More that fails keeps the rows and says so, and the next one tries
/// again. A More that is refused, or finds the DataGateway gone, counts as a read
/// that was.
///
/// ## Actions
///
/// An action answers with the link as the server left it. It replaces the row
/// while its new status is still under the filter, and takes the row off when
/// it isn't. Actions on different rows run side by side. One asked for on a
/// row already busy is dropped, and so is a link that names no tag.
///
/// - A 404 says the link, or the DataGateway, is gone. The row comes off at
///   once and the list is read again. If that read finds the DataGateway gone
///   too, the list is [LanguageLinkListGone].
/// - An accept the server won't make (409) keeps the row, and the list is read
///   again, to show how the link was settled.
/// - A link to a tag the server doesn't have keeps the row. That is a 400 from
///   the API, and only that: the remote calls a proxy's 400 transient, and an
///   answer that came back and couldn't be read is a permanent failure too, but
///   the link may have been made, so each counts as no answer (#627).
/// - A refusal (403) keeps the row. See Access.
/// - Anything else keeps the row and reads nothing more. The change may have
///   been made, and the banner says so. Reading again wouldn't help: an action
///   on one link can't make another wrong, and on a flaky connection a read
///   that failed would take the whole list down.
///
/// ## Reads and actions overlap
///
/// The user can refresh, come back to the screen or change the filter while an
/// action runs. The server may have answered that read before it made the
/// action's change, and then its rows show the link as it was. So:
///
/// - A read that lands during an action shows its rows. The action settles its
///   row against the rows shown when it ends, whichever read brought them, and
///   then reads the list again.
/// - A read still in flight when an action ends is dropped, and one more goes
///   out. It is marked dropped in the turn the action ends, so it can't land
///   between that and the next read starting.
/// - Of two overlapping reads, the one asked for last wins, whichever answers
///   first.
///
/// An action can end with its row nowhere on screen: the filter changed, and
/// the new rows don't hold it. It is left for the read that follows, which
/// knows where it goes. Its outcome shows anyway, under the new filter: how the
/// action ended is news the user hasn't been told yet.
///
/// A read that fails, is refused or finds the DataGateway gone takes the rows
/// down, during an action as at any other time. An action that ends then keeps
/// its outcome, which shows once a read brings the rows back, and asks for no
/// read of its own: the screen already offers a retry.
///
/// ## Leaving during an action
///
/// A handler waiting on the server outlives [close], and asking for a read then
/// would throw, so it asks for none once [close] has started. A refusal that
/// lands after that still reaches [access], which outlasts the screen.
///
/// ## Access
///
/// A refused read is [LanguageLinkListDenied]. A refused change hides every
/// action for the rest of the session, here and on every other screen, through
/// [DataGatewayAccess]: Moderators may read DataGateways and their links and
/// not change them, and nothing tells the client which role it has until a
/// change is refused (#41). Both are reported to [access], so the home drawer
/// agrees with what this screen found.
///
/// A null [access] is a composition with no session to report to. The screen
/// still works; what it learns lasts as long as the bloc.
class LanguageLinkListBloc
    extends Bloc<LanguageLinkListEvent, LanguageLinkListState> {
  LanguageLinkListBloc({
    required this._remote,
    required this._gatewayId,
    DataGatewayAccess? access,
    BgeLogger? logger,
  }) : _access = access,
       _logger = logger ?? BgeLogger('bge.data_gateway.language_links'),
       _mayChange = access?.value.mayChange ?? true,
       super(const LanguageLinkListLoading(LanguageLinkFilter.waiting)) {
    on<LanguageLinkListLoadRequested>((_, emit) => _read(emit));
    on<LanguageLinkListFilterChanged>(_onFilterChanged);
    on<LanguageLinkListMoreRequested>(_onMoreRequested);
    on<LanguageLinkListActionRequested>(_onActionRequested);
    on<LanguageLinkListOutcomeDismissed>(_onOutcomeDismissed);
    on<LanguageLinkListAccessChanged>(_onAccessChanged);
    access?.addListener(_accessListener);
  }

  /// The page size every read asks for, which More's arithmetic counts in.
  static const int _pageSize = DataGatewayRemoteDataSource.languageLinkPageSize;

  final DataGatewayRemoteDataSource _remote;
  final String _gatewayId;
  final DataGatewayAccess? _access;
  final BgeLogger _logger;

  bool _mayChange;

  LanguageLinkFilter _filter = LanguageLinkFilter.waiting;

  /// The rows on screen. Null until a read succeeds; again after a read fails,
  /// or a read or a More is refused or finds the DataGateway gone; and from a
  /// filter change until its read answers. A More that fails keeps them.
  List<LanguageLink>? _rows;

  /// How far down the server's list the rows were read: the place just past
  /// the last link read, less one for each row an action has taken off since.
  /// More asks for the page holding the next place.
  ///
  /// The same as the number of rows shown, until a link is added ahead of
  /// them. Then a page holds links already shown, and this runs ahead.
  int _readThrough = 0;

  /// Whether the server has more past the rows shown.
  bool _hasMore = false;

  /// Whether a More is out.
  bool _loadingMore = false;

  /// Which More is the latest. One that answers under an older number was
  /// dropped for an action.
  int _moreSequence = 0;

  /// More has been asked for, and is waiting for what is running to end.
  bool _moreWaiting = false;

  /// The last More failed. Cleared when the next one starts, and when a read
  /// replaces the rows.
  bool _moreFailed = false;

  /// Ids of the rows with an action in flight.
  final Set<String> _busy = {};

  /// What the last action answered, until dismissed or replaced, or until the
  /// filter changes.
  LanguageLinkOutcome? _outcome;

  /// Which read is the latest. A read or a More that answers under an older
  /// number is dropped.
  int _readSequence = 0;

  /// The latest read that has answered. Behind [_readSequence] from when a
  /// read is asked for until it answers, which takes in the gap between an
  /// action dropping a read and the read it asks for in its place starting.
  int _readAnswered = 0;

  /// A read has been asked for and hasn't answered.
  bool get _reading => _readAnswered != _readSequence;

  void _accessListener() => add(const LanguageLinkListAccessChanged());

  Future<void> _onFilterChanged(
    LanguageLinkListFilterChanged event,
    Emitter<LanguageLinkListState> emit,
  ) async {
    if (event.filter == _filter) return;
    _filter = event.filter;
    _rows = null;
    _outcome = null;
    _moreWaiting = false;
    await _read(emit);
  }

  /// Reads the first page under the filter, in place of every row shown.
  Future<void> _read(Emitter<LanguageLinkListState> emit) async {
    final read = ++_readSequence;
    final filter = _filter;
    // A More still out answers for rows this read replaces. Its answer is
    // dropped when it lands, and it stops showing now.
    final droppedMore = _loadingMore;
    _loadingMore = false;
    if (_rows == null) {
      emit(LanguageLinkListLoading(filter));
    } else if (droppedMore) {
      _emitReady(emit);
    }
    try {
      final result = await _remote.fetchLanguageLinks(
        _gatewayId,
        statuses: _statusesOf(filter),
        page: 1,
        limit: _pageSize,
      );
      if (read != _readSequence) return;
      _access?.readGranted();
      _rows = result.items;
      _readThrough = result.items.length;
      _hasMore = result.meta.hasMore;
      _moreWaiting = _moreWaiting && _hasMore;
      _moreFailed = false;
      _emitReady(emit);
    } on DataGatewayForbiddenException {
      if (read != _readSequence) return;
      _access?.readDenied();
      _takeDown(emit, LanguageLinkListDenied(filter));
    } on DataGatewayNotFoundException {
      if (read != _readSequence) return;
      _takeDown(emit, LanguageLinkListGone(filter));
    } on Object catch (error, stackTrace) {
      if (read != _readSequence) return;
      _logger.warn(
        'Language link list read failed',
        error: error,
        stackTrace: stackTrace,
      );
      _takeDown(emit, LanguageLinkListFailed(filter));
    } finally {
      if (read == _readSequence) {
        _readAnswered = read;
        _startWaitingMore();
      }
    }
  }

  /// Asks again for the More that has been waiting, once nothing holds it up.
  void _startWaitingMore() {
    if (_moreWaiting && !_reading && _busy.isEmpty && !isClosed) {
      add(const LanguageLinkListMoreRequested());
    }
  }

  Future<void> _onMoreRequested(
    LanguageLinkListMoreRequested event,
    Emitter<LanguageLinkListState> emit,
  ) async {
    final shown = _rows;
    if (shown == null || !_hasMore || _loadingMore) return;
    if (_reading || _busy.isNotEmpty) {
      _moreWaiting = true;
      _moreFailed = false;
      _emitReady(emit);
      return;
    }

    // Shares the read sequence without moving it, so a read or a filter
    // change asked for while this is out drops its answer.
    final read = _readSequence;
    final more = ++_moreSequence;
    bool dropped() => read != _readSequence || more != _moreSequence;
    final filter = _filter;
    final page = _readThrough ~/ _pageSize + 1;
    _moreWaiting = false;
    _loadingMore = true;
    _moreFailed = false;
    _emitReady(emit);
    try {
      final result = await _remote.fetchLanguageLinks(
        _gatewayId,
        statuses: _statusesOf(filter),
        page: page,
        limit: _pageSize,
      );
      if (dropped()) return;
      _access?.readGranted();
      // Nothing else changes the rows while this is out: an action, a read or a
      // filter change drops it.
      final known = {for (final link in shown) link.id};
      _rows = [
        ...shown,
        for (final link in result.items)
          if (known.add(link.id)) link,
      ];
      // To the end of this page, links already shown included.
      _readThrough = (page - 1) * _pageSize + result.items.length;
      _hasMore = result.meta.hasMore;
      _loadingMore = false;
      _emitReady(emit);
    } on DataGatewayForbiddenException {
      if (dropped()) return;
      _access?.readDenied();
      _takeDown(emit, LanguageLinkListDenied(filter));
    } on DataGatewayNotFoundException {
      if (dropped()) return;
      _takeDown(emit, LanguageLinkListGone(filter));
    } on Object catch (error, stackTrace) {
      if (dropped()) return;
      _logger.warn(
        'Language link page $page failed',
        error: error,
        stackTrace: stackTrace,
      );
      _loadingMore = false;
      _moreFailed = true;
      _emitReady(emit);
    }
  }

  Future<void> _onActionRequested(
    LanguageLinkListActionRequested event,
    Emitter<LanguageLinkListState> emit,
  ) async {
    final row = _rows?.where((link) => link.id == event.linkId).firstOrNull;
    if (row == null || !_mayChange || _busy.contains(row.id)) return;
    final request = _request(event.action, row.id, event.tagId);
    if (request == null) return;

    if (_loadingMore) {
      _moreSequence++;
      _loadingMore = false;
      _moreWaiting = true;
    }
    _busy.add(row.id);
    _emitReady(emit);
    final answeredBefore = _readAnswered;

    final end = await _attempt(event.action, request);

    // All in one turn. A read in flight is marked dropped before anything
    // yields, so it can't land between busy clearing and the read asked for
    // below starting.
    _busy.remove(row.id);
    final overtaken = _reading;
    if (overtaken) _readSequence++;
    final landed = _readAnswered != answeredBefore;
    final shown = _rows != null;
    _settle(row.id, event.action, end);
    _outcome = LanguageLinkOutcome(
      kind: end.kind,
      value: row.value,
      format: row.format,
    );
    _emitReady(emit);

    // One more read in place of the one dropped; over rows a read brought
    // during the action, which may be older than its change; and after an
    // answer that leaves the list in doubt. None while the list is down: the
    // screen offers its own retry.
    final readAgain = overtaken || (shown && (landed || end.readsAgain));
    if (readAgain && !isClosed) {
      add(const LanguageLinkListLoadRequested());
    } else {
      _startWaitingMore();
    }
  }

  /// The call [action] makes on the link [linkId]. Null for a link that names
  /// no tag, which has nothing to send.
  Future<LanguageLink> Function()? _request(
    LanguageLinkAction action,
    String linkId,
    String? tagId,
  ) => switch (action) {
    LanguageLinkAction.link when tagId != null =>
      () => _remote.linkLanguageLink(_gatewayId, linkId, tagId),
    LanguageLinkAction.link => null,
    LanguageLinkAction.ignore => () => _remote.ignoreLanguageLink(
      _gatewayId,
      linkId,
    ),
    LanguageLinkAction.accept => () => _remote.acceptLanguageLink(
      _gatewayId,
      linkId,
    ),
  };

  /// Sends [request] for [action], and answers with how it ended. Never
  /// throws.
  Future<_ActionEnd> _attempt(
    LanguageLinkAction action,
    Future<LanguageLink> Function() request,
  ) async {
    try {
      final link = await request();
      return _ActionEnd(switch (action) {
        LanguageLinkAction.link => LanguageLinkOutcomeKind.linked,
        LanguageLinkAction.ignore => LanguageLinkOutcomeKind.ignored,
        LanguageLinkAction.accept => LanguageLinkOutcomeKind.accepted,
      }, link);
    } on DataGatewayForbiddenException {
      _mayChange = false;
      _access?.changeDenied();
      return const _ActionEnd(LanguageLinkOutcomeKind.refused);
    } on DataGatewayNotFoundException {
      return const _ActionEnd(LanguageLinkOutcomeKind.gone);
    } on DataGatewayConflictException catch (error, stackTrace) {
      // Accept is the one action the server answers a 409, and the banner for
      // one is about adding a language.
      if (action == LanguageLinkAction.accept) {
        return const _ActionEnd(LanguageLinkOutcomeKind.conflict);
      }
      return _noAnswer(action, error, stackTrace);
    } on DataGatewayPermanentException catch (error, stackTrace) {
      // A 400 from the API to a link names a tag the server doesn't have. A 2xx
      // whose body couldn't be read is permanent too, and the link may have
      // been made.
      if (action == LanguageLinkAction.link && error.statusCode == 400) {
        return const _ActionEnd(LanguageLinkOutcomeKind.unknownTag);
      }
      return _noAnswer(action, error, stackTrace);
    } on Object catch (error, stackTrace) {
      return _noAnswer(action, error, stackTrace);
    }
  }

  _ActionEnd _noAnswer(
    LanguageLinkAction action,
    Object error,
    StackTrace stackTrace,
  ) {
    _logger.warn(
      'Language link ${action.name} failed',
      error: error,
      stackTrace: stackTrace,
    );
    return const _ActionEnd(LanguageLinkOutcomeKind.noAnswer);
  }

  /// Settles the row [id], which [action] was asked on, against the rows
  /// shown now, whichever read brought them: the server's link replaces it
  /// while still under the filter, and takes it off when not; a link found
  /// gone comes off; and an action that said nothing about it leaves it be. A
  /// row not shown is left for the read that follows.
  void _settle(String id, LanguageLinkAction action, _ActionEnd end) {
    final rows = _rows;
    if (rows == null) return;
    final link = end.link;
    final keep = link == null
        ? end.kind != LanguageLinkOutcomeKind.gone
        : _lists(_filter, link.status);
    final settled = [
      for (final shown in rows)
        if (shown.id != id) shown else if (keep) link ?? shown,
    ];
    // A row taken off moves the server's later links up a place. Not past the
    // first: a lost answer on the row may have counted that place already.
    final taken = rows.length - settled.length;
    _readThrough = _readThrough > taken ? _readThrough - taken : 0;
    // So may a lost answer, which keeps its row: see Pages.
    if (end.kind == LanguageLinkOutcomeKind.noAnswer &&
        !_lists(_filter, _statusAfter(action)) &&
        _readThrough > 0) {
      _readThrough--;
    }
    _rows = settled;
  }

  /// The status [action] leaves a link in, once the server has made it.
  static LanguageLinkStatus _statusAfter(LanguageLinkAction action) =>
      switch (action) {
        LanguageLinkAction.link ||
        LanguageLinkAction.accept => LanguageLinkStatus.resolved,
        LanguageLinkAction.ignore => LanguageLinkStatus.ignored,
      };

  void _onOutcomeDismissed(
    LanguageLinkListOutcomeDismissed event,
    Emitter<LanguageLinkListState> emit,
  ) {
    if (_outcome == null) return;
    _outcome = null;
    _emitReady(emit);
  }

  void _onAccessChanged(
    LanguageLinkListAccessChanged event,
    Emitter<LanguageLinkListState> emit,
  ) {
    final access = _access;
    if (access == null || access.value.mayChange || !_mayChange) return;
    _mayChange = false;
    _emitReady(emit);
  }

  /// Takes the rows down, and shows [state] in their place.
  void _takeDown(
    Emitter<LanguageLinkListState> emit,
    LanguageLinkListState state,
  ) {
    _rows = null;
    _loadingMore = false;
    _moreWaiting = false;
    emit(state);
  }

  /// Shows the rows, when there are rows to show.
  void _emitReady(Emitter<LanguageLinkListState> emit) {
    final rows = _rows;
    if (rows == null) return;
    emit(
      LanguageLinkListReady(
        filter: _filter,
        links: rows,
        hasMore: _hasMore,
        loadingMore: _loadingMore || _moreWaiting,
        moreFailed: _moreFailed,
        mayChange: _mayChange,
        busy: {..._busy},
        outcome: _outcome,
      ),
    );
  }

  /// The statuses a read under [filter] names. None for waiting, so the
  /// server's own default applies.
  static Set<LanguageLinkStatus>? _statusesOf(LanguageLinkFilter filter) =>
      switch (filter) {
        LanguageLinkFilter.waiting => null,
        LanguageLinkFilter.ignored => const {LanguageLinkStatus.ignored},
        LanguageLinkFilter.resolved => const {LanguageLinkStatus.resolved},
      };

  /// Whether [filter] lists a link in [status].
  static bool _lists(LanguageLinkFilter filter, LanguageLinkStatus status) =>
      switch (filter) {
        LanguageLinkFilter.waiting =>
          status == LanguageLinkStatus.pending ||
              status == LanguageLinkStatus.unresolved,
        LanguageLinkFilter.ignored => status == LanguageLinkStatus.ignored,
        LanguageLinkFilter.resolved => status == LanguageLinkStatus.resolved,
      };

  @override
  Future<void> close() {
    _access?.removeListener(_accessListener);
    return super.close();
  }
}

/// How an action ended.
final class _ActionEnd {
  const _ActionEnd(this.kind, [this.link]);

  final LanguageLinkOutcomeKind kind;

  /// The link as the server left it. Null when the action didn't say.
  final LanguageLink? link;

  /// The answer leaves the list in doubt, so it is read again: the link, or
  /// the DataGateway, is gone, or an accept found the link settled.
  bool get readsAgain =>
      kind == LanguageLinkOutcomeKind.gone ||
      kind == LanguageLinkOutcomeKind.conflict;
}
