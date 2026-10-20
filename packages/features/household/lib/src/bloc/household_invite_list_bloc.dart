import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../invites/household_invite_permissions.dart';
import 'household_invite_list_event.dart';
import 'household_invite_list_state.dart';
import 'invite_pages.dart';

/// Drives a household's invite list (#455, #454, #489): the server's open
/// invites, and the withdraw, revoke and approve actions that settle them.
///
/// Nothing is cached. The list is read whenever the screen opens and
/// whenever the person comes back from sending an invite.
///
/// ## Reads and actions overlap
///
/// The rows and their pages follow [InvitePages]. The busy set and the last
/// outcome live in fields here rather than only in the emitted state, for
/// the same reason the rows do. A reload over rows already shown keeps
/// showing them.
///
/// An action's answer is the invite as the server left it, so it replaces
/// the row, or drops it when the invite no longer belongs under the filter.
/// An action that ends while a read is in flight asks for the list again:
/// the server may have answered that read before the action's write.
///
/// A refusal that says the list is out of date asks for it again too: the
/// invite was already settled (409), expired (410) or is gone (404), or the
/// viewer's role changed (403).
///
/// ## Who is looking
///
/// Read from the local cache with each load, since the cache may be cold
/// when the screen opens from a deep link. When it cannot say, no row
/// offers an action; the server would decide anyway.
class HouseholdInviteListBloc
    extends Bloc<HouseholdInviteListEvent, HouseholdInviteListState> {
  HouseholdInviteListBloc({
    required this._householdId,
    required this._remote,
    required this._repository,
    this._pageSize = HouseholdInviteRemoteDataSource.defaultPageSize,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.invites'),
       super(const HouseholdInviteListLoading()) {
    _pages = InvitePages(
      fetch: (page, limit) => _remote.fetchHouseholdInvites(
        _householdId,
        status: _status,
        page: page,
        limit: limit,
      ),
      pageSize: _pageSize,
      logger: _logger,
    );
    on<HouseholdInviteListLoadRequested>((_, emit) => _load(emit));
    on<HouseholdInviteListFilterChanged>(_onFilterChanged);
    on<HouseholdInviteListMoreRequested>(_onMoreRequested);
    on<HouseholdInviteListActionRequested>(_onActionRequested);
    on<HouseholdInviteListOutcomeDismissed>(_onOutcomeDismissed);
  }

  final String _householdId;
  final HouseholdInviteRemoteDataSource _remote;
  final HouseholdRepository _repository;
  final int _pageSize;
  final BgeLogger _logger;

  HouseholdInviteFilter _filter = HouseholdInviteFilter.open;

  /// The filter the list is under, including while its first read runs.
  HouseholdInviteFilter get filter => _filter;

  late final InvitePages _pages;

  String? _viewerUserId;
  HouseholdRole? _viewerRole;

  /// Ids of the rows with an action in flight.
  final Set<String> _busy = {};

  /// What the last action answered, until dismissed or replaced.
  HouseholdInviteListOutcome? _outcome;

  HouseholdInviteStatus? get _status => switch (_filter) {
    HouseholdInviteFilter.open => null,
    HouseholdInviteFilter.awaitingApproval =>
      HouseholdInviteStatus.awaitingApproval,
  };

  Future<void> _onFilterChanged(
    HouseholdInviteListFilterChanged event,
    Emitter<HouseholdInviteListState> emit,
  ) async {
    if (event.filter != _filter) {
      // The rows under the old filter are not the new filter's, so the list
      // starts over from the spinner rather than showing them under it.
      _filter = event.filter;
      _pages.clear();
    }
    await _load(emit);
  }

  Future<void> _load(Emitter<HouseholdInviteListState> emit) async {
    // Carries the filter, so a filter changed before the first read answers
    // is a new state, and the control redraws.
    if (_pages.rows == null) emit(HouseholdInviteListLoading(filter: _filter));
    // Read before the list, so the read that wins brings its own viewer.
    final member = await _readViewer();
    try {
      if (!await _pages.load()) return;
    } on HouseholdInviteRefusedException catch (error) {
      if (error.statusCode == 403) {
        emit(const HouseholdInviteListDenied());
      } else {
        _logger.warn('Household invite list refused', error: error);
        emit(const HouseholdInviteListFailed());
      }
      return;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household invite list read failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const HouseholdInviteListFailed());
      return;
    }
    _viewerUserId = member?.userId;
    _viewerRole = member?.role;
    _emitReady(emit);
    if (_pages.moreWaiting && !isClosed) {
      add(const HouseholdInviteListMoreRequested());
    }
  }

  /// Who is looking. Never throws: not knowing is an answer here.
  Future<HouseholdMember?> _readViewer() async {
    try {
      return await _repository.getCurrentUserMember(_householdId);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Could not read who is viewing the invite list',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> _onMoreRequested(
    HouseholdInviteListMoreRequested event,
    Emitter<HouseholdInviteListState> emit,
  ) => _pages.more(() => _emitReady(emit));

  Future<void> _onActionRequested(
    HouseholdInviteListActionRequested event,
    Emitter<HouseholdInviteListState> emit,
  ) async {
    final id = event.inviteId;
    final viewer = _viewerUserId;
    final row = _pages.rows?.where((invite) => invite.id == id).firstOrNull;
    if (row == null || viewer == null || _busy.contains(id)) return;
    final allowed = HouseholdInvitePermissions.rowActions(
      viewerUserId: viewer,
      viewerRole: _viewerRole,
      invite: row,
    );
    if (!allowed.contains(event.action)) return;

    _busy.add(id);
    _outcome = null;
    _emitReady(emit);

    final (after, result, error) = await _attempt(event.action, row);

    // Settled against the rows as they are now, not as they were when the
    // action started: a reload or another row's action may have landed. A
    // failed or refused action says nothing about the row, so whatever is
    // there now stays.
    _busy.remove(id);
    final rows = _pages.rows;
    if (rows != null && after != null) {
      _pages.rows = [
        for (final invite in rows)
          if (invite.id != id) invite else if (_belongs(after)) after,
      ];
    }
    _outcome = HouseholdInviteListOutcome(
      action: event.action,
      result: result,
      error: error,
    );
    _emitReady(emit);

    final outOfDate =
        error is HouseholdInviteRefusedException &&
        const {403, 404, 409, 410}.contains(error.statusCode);
    if ((_pages.reading || outOfDate) && !isClosed) {
      add(const HouseholdInviteListLoadRequested());
    }
  }

  /// Whether [invite] belongs on the list under the current filter.
  bool _belongs(HouseholdInvite invite) => switch (_filter) {
    HouseholdInviteFilter.open => invite.status.isOutstanding,
    HouseholdInviteFilter.awaitingApproval =>
      invite.status == HouseholdInviteStatus.awaitingApproval,
  };

  /// Runs [action] on [row]. Answers with the invite as the server left it,
  /// how the action ended, and what it failed with. Never throws.
  Future<(HouseholdInvite?, HouseholdInviteActionResult, Object?)> _attempt(
    HouseholdInviteRowAction action,
    HouseholdInvite row,
  ) async {
    try {
      final answer = await switch (action) {
        HouseholdInviteRowAction.withdraw => _remote.withdraw(row.id),
        HouseholdInviteRowAction.revoke => _remote.revoke(_householdId, row.id),
        HouseholdInviteRowAction.approve => _remote.approve(
          _householdId,
          row.id,
        ),
      };
      return (answer, HouseholdInviteActionResult.done, null);
    } on HouseholdInviteRefusedException catch (error) {
      return (null, HouseholdInviteActionResult.refused, error);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household invite ${action.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
      return (null, HouseholdInviteActionResult.failed, error);
    }
  }

  void _onOutcomeDismissed(
    HouseholdInviteListOutcomeDismissed event,
    Emitter<HouseholdInviteListState> emit,
  ) {
    if (_outcome == null) return;
    _outcome = null;
    _emitReady(emit);
  }

  /// Shows the rows, when there are rows to show.
  void _emitReady(Emitter<HouseholdInviteListState> emit) {
    final rows = _pages.rows;
    if (rows == null) return;
    emit(
      HouseholdInviteListReady(
        invites: rows,
        filter: _filter,
        hasMore: _pages.hasMore,
        loadingMore: _pages.loadingMore,
        viewerUserId: _viewerUserId,
        viewerRole: _viewerRole,
        busy: {..._busy},
        outcome: _outcome,
      ),
    );
  }
}
