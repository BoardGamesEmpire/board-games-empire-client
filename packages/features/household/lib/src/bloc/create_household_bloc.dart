import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:models/domain.dart';

import 'create_household_event.dart';
import 'create_household_state.dart';

/// Drives household creation (#27/#39/#40), coordinating the local write
/// and the online-first server sync:
///
/// 1. [HouseholdRepository.create] writes the optimistic household + owner
///    member and enqueues a `CreateHouseholdOperation` (one transaction).
///    The household is visible from this point on.
/// 2. Best-effort inline send via [HouseholdRemoteDataSource.createHousehold]:
///    - success → [HouseholdRepository.reconcileCreatedHousehold] confirms
///      the row (canonical id, flags cleared) and closes the queued op, so
///      the future sync worker (#121) won't re-create it → `pendingSync: false`.
///    - failure (transient **or** permanent) → the optimistic household stays
///      queued for a later retry; the create still succeeded locally →
///      `pendingSync: true`.
///
/// There is no sync worker yet (#121), so the inline send is the only thing
/// pushing the create to the server today; when it fails the household is
/// simply queued. Distinguishing permanent failures for rollback (and
/// cancelling their queue entry) is deferred to #121, which will own retry /
/// failure / cancel semantics.
class CreateHouseholdBloc
    extends Bloc<CreateHouseholdEvent, CreateHouseholdState> {
  CreateHouseholdBloc({
    required HouseholdRepository repository,
    required this._remote,
    BgeLogger? logger,
  }) : _repo = repository,
       _logger = logger ?? BgeLogger('bge.household.create'),
       super(const CreateHouseholdInitial()) {
    on<CreateHouseholdSubmitted>(_onSubmitted);
  }

  final HouseholdRepository _repo;
  final HouseholdRemoteDataSource _remote;
  final BgeLogger _logger;

  Future<void> _onSubmitted(
    CreateHouseholdSubmitted event,
    Emitter<CreateHouseholdState> emit,
  ) async {
    // Re-entrancy guard: ignore submits while one is in flight.
    if (state is CreateHouseholdSubmitting) return;
    emit(const CreateHouseholdSubmitting());

    final ({Household household, String syncQueueId}) draft;
    try {
      draft = await _repo.create(
        name: event.name,
        description: event.description,
      );
    } on Object catch (error, stackTrace) {
      _logger.error(
        'Local household create failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const CreateHouseholdFailure());
      return;
    }

    try {
      // Send the canonical (trimmed) values the repository persisted, so the
      // server and the local row agree and the reconcile upsert can't
      // reintroduce an untrimmed name.
      final server = await _remote.createHousehold(
        name: draft.household.name,
        description: draft.household.description,
      );
      try {
        await _repo.reconcileCreatedHousehold(
          server,
          localId: draft.household.id,
          completedSyncQueueId: draft.syncQueueId,
        );
        emit(
          CreateHouseholdSuccess(householdId: server.id, pendingSync: false),
        );
      } on Object catch (error, stackTrace) {
        // The server created the household but the local reconcile failed and
        // rolled back (transactional): the optimistic row still stands and the
        // op is still queued. Surface as pending rather than stranding the UI
        // in "submitting" forever (the re-entrancy guard would drop retries).
        _logger.error(
          'Household reconcile failed after a successful server create; '
          'left queued',
          error: error,
          stackTrace: stackTrace,
        );
        emit(
          CreateHouseholdSuccess(
            householdId: draft.household.id,
            pendingSync: true,
          ),
        );
      }
    } on HouseholdRemoteException catch (error) {
      _logger.warn(
        'Inline household sync failed (${error.runtimeType}); '
        'left queued for retry',
        error: error,
      );
      emit(
        CreateHouseholdSuccess(
          householdId: draft.household.id,
          pendingSync: true,
        ),
      );
    }
  }
}
