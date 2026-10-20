import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../invites/invite_refusal_message.dart';
import 'household_invite_list_state.dart';
import 'invite_inbox_event.dart';
import 'invite_inbox_state.dart';
import 'invite_pages.dart';

/// Drives the invite inbox (#455, #454): the pending invites sent to the
/// user, and accepting or declining them. The server leaves out an invite
/// awaiting approval until it is approved.
///
/// Nothing is cached; the inbox is read when the screen opens. The rows and
/// their pages follow [InvitePages], and an answer settles against the rows
/// on screen when it ends, as the household invite list's actions do (see
/// `HouseholdInviteListBloc`).
///
/// After an accept, [onJoined] brings the household onto the device. It is
/// not awaited: the inbox has its answer, and the hydrate pass reports
/// through its own status.
class InviteInboxBloc extends Bloc<InviteInboxEvent, InviteInboxState> {
  InviteInboxBloc({
    required this._remote,
    this._onJoined,
    this._pageSize = HouseholdInviteRemoteDataSource.defaultPageSize,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.invites.inbox'),
       super(const InviteInboxLoading()) {
    _pages = InvitePages(
      fetch: (page, limit) => _remote.fetchInbox(page: page, limit: limit),
      pageSize: _pageSize,
      logger: _logger,
    );
    on<InviteInboxLoadRequested>((_, emit) => _load(emit));
    on<InviteInboxMoreRequested>(_onMoreRequested);
    on<InviteInboxAnswerRequested>(_onAnswerRequested);
    on<InviteInboxOutcomeDismissed>(_onOutcomeDismissed);
  }

  final HouseholdInviteRemoteDataSource _remote;
  final Future<void> Function(String householdId)? _onJoined;
  final int _pageSize;
  final BgeLogger _logger;

  late final InvitePages _pages;
  final Set<String> _busy = {};
  InviteInboxOutcome? _outcome;

  Future<void> _load(Emitter<InviteInboxState> emit) async {
    if (_pages.rows == null) emit(const InviteInboxLoading());
    try {
      if (!await _pages.load()) return;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Invite inbox read failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const InviteInboxFailed());
      return;
    }
    _emitReady(emit);
    if (_pages.moreWaiting && !isClosed) add(const InviteInboxMoreRequested());
  }

  Future<void> _onMoreRequested(
    InviteInboxMoreRequested event,
    Emitter<InviteInboxState> emit,
  ) => _pages.more(() => _emitReady(emit));

  Future<void> _onAnswerRequested(
    InviteInboxAnswerRequested event,
    Emitter<InviteInboxState> emit,
  ) async {
    final id = event.inviteId;
    final row = _pages.rows?.where((invite) => invite.id == id).firstOrNull;
    if (row == null || _busy.contains(id)) return;
    const answers = {
      HouseholdInviteAction.accept,
      HouseholdInviteAction.decline,
    };
    if (!answers.contains(event.action)) return;

    _busy.add(id);
    _outcome = null;
    _emitReady(emit);

    String? joined;
    HouseholdInviteActionResult result;
    Object? failure;
    try {
      if (event.action == HouseholdInviteAction.accept) {
        joined = (await _remote.accept(id)).householdId;
      } else {
        await _remote.decline(id);
      }
      result = HouseholdInviteActionResult.done;
    } on HouseholdInviteRefusedException catch (error) {
      result = HouseholdInviteActionResult.refused;
      failure = error;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Invite ${event.action.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
      result = HouseholdInviteActionResult.failed;
      failure = error;
    }

    _busy.remove(id);
    // An answered invite leaves the inbox whatever its new status: the
    // inbox lists only open invites.
    final rows = _pages.rows;
    if (rows != null && result == HouseholdInviteActionResult.done) {
      _pages.rows = [
        for (final invite in rows)
          if (invite.id != id) invite,
      ];
    }
    _outcome = InviteInboxOutcome(
      action: event.action,
      result: result,
      householdName: row.householdName ?? '',
      householdId: joined,
      error: failure,
    );
    _emitReady(emit);

    final onJoined = _onJoined;
    if (joined != null && onJoined != null) unawaited(onJoined(joined));

    final outOfDate =
        failure is HouseholdInviteRefusedException &&
        const {404, 409, 410}.contains(failure.statusCode);
    if ((_pages.reading || outOfDate) && !isClosed) {
      add(const InviteInboxLoadRequested());
    }
  }

  void _onOutcomeDismissed(
    InviteInboxOutcomeDismissed event,
    Emitter<InviteInboxState> emit,
  ) {
    if (_outcome == null) return;
    _outcome = null;
    _emitReady(emit);
  }

  void _emitReady(Emitter<InviteInboxState> emit) {
    final rows = _pages.rows;
    if (rows == null) return;
    emit(
      InviteInboxReady(
        invites: rows,
        hasMore: _pages.hasMore,
        loadingMore: _pages.loadingMore,
        busy: {..._busy},
        outcome: _outcome,
      ),
    );
  }
}
