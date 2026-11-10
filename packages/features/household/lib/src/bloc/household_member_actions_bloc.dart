import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:household/src/bloc/household_member_actions_event.dart';
import 'package:household/src/bloc/household_member_actions_state.dart';
import 'package:household/src/members/send_member_request.dart';
import 'package:household/src/permissions/household_actions.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Changes a household member's role, removes them, or makes them the
/// owner, from the household screen (#480, #478).
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
/// | 200 | answer written, or row deleted | done | started |
/// | An enveloped 404 | untouched | gone | started |
/// | An enveloped 400, 403 or 409 | untouched | refused | started |
/// | Transient | untouched | failed | none |
/// | Anything else | untouched | failed | started |
///
/// On a 200 for a transfer, both sides stay cached with the answer written.
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
    on<HouseholdMemberOwnershipTransferRequested>(_onTransferRequested);
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
      // Over the cached row only: a hydrate may have dropped the member
      // while the request was out, and an upsert would put them back.
      cache: (member) => _repository.updateCachedMembers([member]),
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

  Future<void> _onTransferRequested(
    HouseholdMemberOwnershipTransferRequested event,
    Emitter<HouseholdMemberActionsState> emit,
  ) {
    final member = event.member;
    return _act(
      emit,
      member,
      HouseholdMemberAction.makeOwner,
      send: () => _remote.transferOwnership(member.householdId, member.id),
      // Rows still cached only: the viewer may have left while this was on
      // its way, and an upsert would bring the household back.
      cache: (answer) =>
          _repository.updateCachedMembers([answer.owner, answer.previousOwner]),
    );
  }

  /// Runs [action] on [member] and reports how it went, unless [member] is
  /// busy.
  Future<void> _act<T>(
    Emitter<HouseholdMemberActionsState> emit,
    HouseholdMember member,
    HouseholdMemberAction action, {
    required Future<T> Function() send,
    required Future<void> Function(T answer) cache,
  }) async {
    final id = member.id;
    // Checked and marked before anything is awaited, so a second request
    // for the member, handled while this one waits, finds it busy.
    if (state.busy.contains(id)) return;
    // The last banner described another request, so it goes.
    emit(
      HouseholdMemberActionsState(busy: Set.unmodifiable({...state.busy, id})),
    );

    final o = await sendMemberRequest<T>(
      action: action.name,
      send: send,
      cache: cache,
      refresh: _onChanged,
      logger: _logger,
    );
    final outcome = HouseholdMemberOutcome(
      action: action,
      result: o.result,
      error: o.error,
    );

    // Read again: another member's request may have started or ended
    // meanwhile.
    emit(
      HouseholdMemberActionsState(
        busy: Set.unmodifiable({...state.busy}..remove(id)),
        outcome: outcome,
      ),
    );
  }

  void _onOutcomeDismissed(
    HouseholdMemberOutcomeDismissed event,
    Emitter<HouseholdMemberActionsState> emit,
  ) {
    if (state.outcome == null) return;
    emit(HouseholdMemberActionsState(busy: state.busy));
  }
}
