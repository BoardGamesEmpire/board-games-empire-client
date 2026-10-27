import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../permissions/household_actions.dart';
import 'household_member_actions_event.dart';
import 'household_member_actions_state.dart';

/// Changes a household member's role, or removes them, from the household
/// screen (#480).
///
/// Each request goes straight to the server, never through the sync queue
/// (#122): nothing is queued and no row is marked dirty. The answer to a 200
/// is written to the cache, and then [_onChanged] marks the household list
/// stale and reads it again. That pass catches a hydrate that read the
/// roster before the change and would write the old one back. Nothing is
/// retried on its own.
///
/// The household is the member's own, `HouseholdMember.householdId`. These
/// actions are offered only on a household the server has confirmed, so it
/// is the server's id.
///
/// ## Answers
///
/// | Answer | Cache | Outcome | Refresh |
/// |---|---|---|---|
/// | 200 | the answer written, or the row deleted | done | started |
/// | An enveloped 404 | untouched | gone | started |
/// | An enveloped 400, 403 or 409 | untouched | refused | started |
/// | Transient | untouched | failed | none |
/// | Anything else | untouched | failed | started |
///
/// A 404 deletes nothing. It says the member is gone or the household is,
/// and a server without the route answers the same, so the refresh, not
/// the answer, takes a member off the list. A 403 still refreshes, since the
/// viewer's own role may have changed on another device. A failure that is
/// not transient may have been a success this device could not read.
///
/// ## Several at once
///
/// Requests for different members run side by side, each member in
/// [HouseholdMemberActionsState.busy] until its outcome is emitted. A
/// request for a member already there is dropped, so a double tap sends
/// one.
class HouseholdMemberActionsBloc
    extends Bloc<HouseholdMemberActionsEvent, HouseholdMemberActionsState> {
  HouseholdMemberActionsBloc({
    required this._remote,
    required this._repository,
    required this._onChanged,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.member_actions'),
       super(const HouseholdMemberActionsState()) {
    // The default transformer, which runs requests concurrently. A
    // droppable one would also drop a request for another member; [_act]
    // drops only a request for a member who is busy.
    on<HouseholdMemberRoleChangeRequested>(_onRoleChangeRequested);
    on<HouseholdMemberRemovalRequested>(_onRemovalRequested);
    on<HouseholdMemberOutcomeDismissed>(_onOutcomeDismissed);
  }

  final HouseholdMemberRemoteDataSource _remote;
  final HouseholdRepository _repository;

  /// Marks the household list stale and reads it again, as
  /// `refreshAfterMembershipChange` does. Started, never awaited, after
  /// every answer but a transient failure.
  ///
  /// Required: the refresh is what takes a member off the list after a 404,
  /// and the banners after a refusal or an unexpected failure say the
  /// household is being read again.
  final Future<void> Function() _onChanged;
  final BgeLogger _logger;

  Future<void> _onRoleChangeRequested(
    HouseholdMemberRoleChangeRequested event,
    Emitter<HouseholdMemberActionsState> emit,
  ) {
    final member = event.member;
    return _act(
      emit,
      member,
      HouseholdMemberAction.changeRole,
      send: () => _remote.changeRole(member.householdId, member.id, event.role),
      cache: _repository.cacheMember,
    );
  }

  Future<void> _onRemovalRequested(
    HouseholdMemberRemovalRequested event,
    Emitter<HouseholdMemberActionsState> emit,
  ) {
    final member = event.member;
    return _act(
      emit,
      member,
      HouseholdMemberAction.remove,
      send: () => _remote.remove(member.householdId, member.id),
      cache: (_) =>
          _repository.removeCachedMember(member.householdId, member.userId),
    );
  }

  /// Runs [action] on [member] and reports how it went, unless [member] is
  /// busy.
  Future<void> _act(
    Emitter<HouseholdMemberActionsState> emit,
    HouseholdMember member,
    HouseholdMemberAction action, {
    required Future<HouseholdMember> Function() send,
    required Future<void> Function(HouseholdMember answer) cache,
  }) async {
    final id = member.id;
    // Checked and marked before anything is awaited, so a second request
    // for the member, handled while this one waits, finds it busy.
    if (state.busy.contains(id)) return;
    // The last banner described another request, so it goes.
    emit(
      HouseholdMemberActionsState(busy: Set.unmodifiable({...state.busy, id})),
    );

    final outcome = await _attempt(action, send, cache);

    // Read again: another member's request may have started or ended
    // meanwhile.
    emit(
      HouseholdMemberActionsState(
        busy: Set.unmodifiable({...state.busy}..remove(id)),
        outcome: outcome,
      ),
    );
  }

  /// Sends a request, caches the answer to a 200, and starts the refresh
  /// the answer calls for. Answers how it ended. Never throws.
  Future<HouseholdMemberOutcome> _attempt(
    HouseholdMemberAction action,
    Future<HouseholdMember> Function() send,
    Future<void> Function(HouseholdMember answer) cache,
  ) async {
    final HouseholdMember answer;
    try {
      answer = await send();
    } on HouseholdMemberRefusedException catch (error) {
      _refresh();
      return HouseholdMemberOutcome(
        action: action,
        result: error.statusCode == 404
            ? HouseholdMemberActionResult.gone
            : HouseholdMemberActionResult.refused,
        error: error,
      );
    } on HouseholdMemberTransientException catch (error, stackTrace) {
      // Nothing is written here and no refresh starts (#122). The server
      // may have made the change before the answer was lost, and the next
      // hydrate brings it if so.
      _logger.warn(
        'Household member ${action.name} got no answer',
        error: error,
        stackTrace: stackTrace,
      );
      return HouseholdMemberOutcome(
        action: action,
        result: HouseholdMemberActionResult.failed,
        error: error,
      );
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household member ${action.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
      _refresh();
      return HouseholdMemberOutcome(
        action: action,
        result: HouseholdMemberActionResult.failed,
        error: error,
      );
    }

    try {
      await cache(answer);
    } on Object catch (error, stackTrace) {
      // The server made the change, and the refresh brings it.
      _logger.warn(
        'Household member ${action.name} done, but its answer was not cached',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _refresh();
    return HouseholdMemberOutcome(
      action: action,
      result: HouseholdMemberActionResult.done,
    );
  }

  void _refresh() => unawaited(_runRefresh());

  Future<void> _runRefresh() async {
    try {
      await _onChanged();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household refresh after a member change failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _onOutcomeDismissed(
    HouseholdMemberOutcomeDismissed event,
    Emitter<HouseholdMemberActionsState> emit,
  ) {
    if (state.outcome == null) return;
    emit(HouseholdMemberActionsState(busy: state.busy));
  }
}
