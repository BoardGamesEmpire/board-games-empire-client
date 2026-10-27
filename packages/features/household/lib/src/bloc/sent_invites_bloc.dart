import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../invites/sent_invite_filter.dart';
import '../permissions/household_actions.dart';
import 'household_invite_list_state.dart';
import 'invite_pages.dart';
import 'sent_invites_event.dart';
import 'sent_invites_state.dart';

/// Drives the list of invites the viewer sent (#487), across every
/// household, and the withdraw that takes one back.
///
/// Nothing is cached; the list is read when the screen opens. The rows and
/// their pages follow [InvitePages], and a withdraw settles against the rows
/// on screen when it ends, as the household invite list's actions do (see
/// `HouseholdInviteListBloc`).
///
/// Every failed read is [SentInvitesFailed], a refusal included: the server
/// refuses this read only to an API key.
class SentInvitesBloc extends Bloc<SentInvitesEvent, SentInvitesState> {
  SentInvitesBloc({
    required this._remote,
    this._pageSize = HouseholdInviteRemoteDataSource.defaultPageSize,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.invites.sent'),
       super(const SentInvitesLoading()) {
    _pages = InvitePages(
      // Read at call time, not captured, so each read asks for the filter
      // as it is when the read begins.
      fetch: (page, limit) =>
          _remote.fetchSent(status: _filter.status, page: page, limit: limit),
      pageSize: _pageSize,
      logger: _logger,
    );
    on<SentInvitesLoadRequested>((_, emit) => _load(emit));
    on<SentInvitesFilterChanged>(_onFilterChanged);
    on<SentInvitesMoreRequested>(_onMoreRequested);
    on<SentInvitesWithdrawRequested>(_onWithdrawRequested);
    on<SentInvitesOutcomeDismissed>(_onOutcomeDismissed);
  }

  final HouseholdInviteRemoteDataSource _remote;
  final int _pageSize;
  final BgeLogger _logger;

  SentInviteFilter _filter = SentInviteFilter.openAndExpired;

  /// The filter the list is under, including while its first read runs.
  SentInviteFilter get filter => _filter;

  late final InvitePages _pages;

  /// Ids of the rows with a withdraw in flight.
  final Set<String> _busy = {};

  /// What the last withdraw answered, until dismissed or replaced.
  HouseholdInviteListOutcome? _outcome;

  Future<void> _onFilterChanged(
    SentInvitesFilterChanged event,
    Emitter<SentInvitesState> emit,
  ) async {
    if (event.filter != _filter) {
      // The rows under the old filter are not the new filter's, so the list
      // starts over from the spinner rather than showing them under it. A
      // withdraw's banner described those rows, so it goes with them; one
      // still in flight reports when it ends.
      _filter = event.filter;
      _pages.clear();
      _outcome = null;
    }
    await _load(emit);
  }

  Future<void> _load(Emitter<SentInvitesState> emit) async {
    // Carries the filter, so a filter changed before the first read answers
    // is a new state, and the control redraws.
    if (_pages.rows == null) emit(SentInvitesLoading(filter: _filter));
    try {
      if (!await _pages.load()) return;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Sent invites read failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const SentInvitesFailed());
      return;
    }
    _emitReady(emit);
    if (_pages.moreWaiting && !isClosed) add(const SentInvitesMoreRequested());
  }

  Future<void> _onMoreRequested(
    SentInvitesMoreRequested event,
    Emitter<SentInvitesState> emit,
  ) => _pages.more(() => _emitReady(emit));

  Future<void> _onWithdrawRequested(
    SentInvitesWithdrawRequested event,
    Emitter<SentInvitesState> emit,
  ) async {
    final id = event.inviteId;
    final row = _pages.rows?.where((invite) => invite.id == id).firstOrNull;
    if (row == null || _busy.contains(id)) return;
    final allowed = sentInviteRowActions(row);
    if (!allowed.contains(HouseholdInviteRowAction.withdraw)) return;

    _busy.add(id);
    _outcome = null;
    _emitReady(emit);
    final mark = _pages.actionMark;

    final (after, result, error) = await _withdraw(id);

    _busy.remove(id);
    final readAgain = _pages.settle(id, after, mark, admits: _filter.admits);
    // Shown even under a filter changed meanwhile: how the withdraw ended
    // is news the person has not been told yet.
    _outcome = HouseholdInviteListOutcome(
      action: HouseholdInviteRowAction.withdraw,
      result: result,
      error: error,
    );
    _emitReady(emit);

    // A refusal that says the row is out of date reads the list again, as
    // the inbox does: the invite was already settled (409), expired (410)
    // or is gone (404). A withdraw's 403 goes to the invitee or a caller
    // who isn't signed in, so it can't come from this list.
    final outOfDate =
        error is HouseholdInviteRefusedException &&
        const {404, 409, 410}.contains(error.statusCode);
    if ((readAgain || outOfDate) && !isClosed) {
      add(const SentInvitesLoadRequested());
    }
  }

  /// Withdraws the invite [id]. Answers with the invite as the server left
  /// it, how the withdraw ended, and what it failed with. Never throws.
  Future<(HouseholdInvite?, HouseholdInviteActionResult, Object?)> _withdraw(
    String id,
  ) async {
    try {
      final answer = await _remote.withdraw(id);
      return (answer, HouseholdInviteActionResult.done, null);
    } on HouseholdInviteRefusedException catch (error) {
      return (null, HouseholdInviteActionResult.refused, error);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Sent invite withdraw failed',
        error: error,
        stackTrace: stackTrace,
      );
      return (null, HouseholdInviteActionResult.failed, error);
    }
  }

  void _onOutcomeDismissed(
    SentInvitesOutcomeDismissed event,
    Emitter<SentInvitesState> emit,
  ) {
    if (_outcome == null) return;
    _outcome = null;
    _emitReady(emit);
  }

  /// Shows the rows, when there are rows to show.
  void _emitReady(Emitter<SentInvitesState> emit) {
    final rows = _pages.rows;
    if (rows == null) return;
    emit(
      SentInvitesReady(
        invites: rows,
        filter: _filter,
        hasMore: _pages.hasMore,
        loadingMore: _pages.loadingMore,
        busy: {..._busy},
        outcome: _outcome,
      ),
    );
  }
}
