import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../members/send_member_request.dart';
import 'household_member_actions_state.dart';
import 'leave_household_event.dart';
import 'leave_household_state.dart';

/// Takes the signed-in person out of a household they chose to leave (#479).
///
/// The request goes straight to the server, never through the sync queue
/// (#122). The answer to a 200 is the person's own removed membership, so the
/// cache write deletes only that row, and the household then disappears
/// behind the repository's membership gate. [_onChanged] then marks the
/// household list stale and reads it again.
///
/// ## Answers
///
/// | Answer | Cache | Phase | Refresh |
/// |---|---|---|---|
/// | 200 | the person's own row deleted | leaving, then left | started |
/// | An enveloped 404 | untouched | idle, gone | started |
/// | An enveloped 400, 403 or 409 | untouched | idle, refused | started |
/// | Transient | untouched | idle, failed | none |
/// | Anything else | untouched | idle, failed | started |
///
/// The phase is leaving from the moment the server says yes until the cache
/// write ends, so the screen is held from popping before the household goes
/// from under it. A request while one is sending or accepted is dropped, so a
/// double tap sends one.
class LeaveHouseholdBloc
    extends Bloc<LeaveHouseholdEvent, LeaveHouseholdState> {
  LeaveHouseholdBloc({
    required this._remote,
    required this._repository,
    required this._onChanged,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.leave'),
       super(const LeaveHouseholdState()) {
    // The default transformer: the guard in [_onRequested] drops the second
    // request, and it needs to see the first one's state.
    on<LeaveHouseholdRequested>(_onRequested);
    on<LeaveHouseholdFailureDismissed>(_onFailureDismissed);
  }

  final HouseholdMemberRemoteDataSource _remote;
  final HouseholdRepository _repository;

  /// Marks the household list stale and reads it again. Started, never
  /// awaited, after every answer but a transient failure.
  final Future<void> Function() _onChanged;
  final BgeLogger _logger;

  Future<void> _onRequested(
    LeaveHouseholdRequested event,
    Emitter<LeaveHouseholdState> emit,
  ) async {
    // Checked and marked before anything is awaited, so a second request,
    // handled while this one waits, finds it busy.
    if (state.busy || state.accepted) return;
    // The last failure described another request, so it goes.
    emit(const LeaveHouseholdState(phase: LeavePhase.sending));

    final outcome = await sendMemberRequest(
      action: 'leave',
      send: () => _remote.leave(event.householdId),
      // The emitter is live: this runs inside the handler while it awaits.
      accepted: (_) =>
          emit(const LeaveHouseholdState(phase: LeavePhase.leaving)),
      cache: (answer) =>
          _repository.removeCachedMember(answer.householdId, answer.userId),
      refresh: _onChanged,
      logger: _logger,
    );

    if (outcome.result == HouseholdMemberActionResult.done) {
      emit(const LeaveHouseholdState(phase: LeavePhase.left));
    } else {
      emit(LeaveHouseholdState(failure: outcome));
    }
  }

  void _onFailureDismissed(
    LeaveHouseholdFailureDismissed event,
    Emitter<LeaveHouseholdState> emit,
  ) {
    if (state.failure == null) return;
    emit(LeaveHouseholdState(phase: state.phase));
  }
}
