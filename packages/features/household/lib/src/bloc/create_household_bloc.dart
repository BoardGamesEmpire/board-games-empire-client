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
/// 2. [SyncQueueRepository.claim] takes the queued op for the inline send
///    (#430). Every sender claims before sending, so this send and a drain
///    or a second tab can't both deliver the op. If the claim is lost,
///    another sender has the op and will deliver it → `pendingSync: true`,
///    with no send from here.
/// 3. Best-effort inline send via [HouseholdRemoteDataSource.createHousehold],
///    keyed by the optimistic row's id. That id is the queued op's `localId`,
///    so the send and every later retry of the op carry one idempotency key,
///    and a send whose response is lost cannot become a second household on
///    the retry (#131):
///    - success → [HouseholdRepository.reconcileCreatedHousehold] confirms
///      the row (canonical id, flags cleared) and closes the queued op, so
///      the future sync worker (#121) won't re-create it → `pendingSync: false`.
///    - a failed request (transient **or** permanent) →
///      [SyncQueueRepository.markFailed], which counts the attempt and keeps
///      its error; the optimistic household stays queued for a later retry,
///      and the create still succeeded locally → `pendingSync: true`.
///    - anything else → [SyncQueueRepository.release], which hands the op
///      back uncounted: it wasn't a failed attempt. That covers an error
///      thrown before any request, such as an `ArgumentError` for a key the
///      server would reject, and a reconcile that fails after the server
///      created the household, whose retry the key dedupes →
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
    required this._syncQueue,
    BgeLogger? logger,
  }) : _repo = repository,
       _logger = logger ?? BgeLogger('bge.household.create'),
       super(const CreateHouseholdInitial()) {
    on<CreateHouseholdSubmitted>(_onSubmitted);
    on<CreateHouseholdFailureCleared>(_onFailureCleared);
  }

  final HouseholdRepository _repo;
  final HouseholdRemoteDataSource _remote;
  final SyncQueueRepository _syncQueue;
  final BgeLogger _logger;

  /// Drops a spent failure back to initial so its banner stops rendering.
  /// Guarded so a stray event cannot wipe a success or an in-flight submit.
  void _onFailureCleared(
    CreateHouseholdFailureCleared event,
    Emitter<CreateHouseholdState> emit,
  ) {
    if (state is CreateHouseholdFailure) emit(const CreateHouseholdInitial());
  }

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

    // From here the household is written and queued, so every outcome below
    // is a success; only `pendingSync` varies.
    final queued = CreateHouseholdSuccess(
      householdId: draft.household.id,
      pendingSync: true,
    );

    final bool claimed;
    try {
      claimed = await _syncQueue.claim(draft.syncQueueId);
    } on Object catch (error, stackTrace) {
      _logger.error(
        'Could not claim the queued household create; left queued',
        error: error,
        stackTrace: stackTrace,
      );
      emit(queued);
      return;
    }
    if (!claimed) {
      // Another sender took the op between the create and here. It is
      // theirs to deliver; sending as well would split the attempt.
      _logger.info('Queued household create is held by another sender');
      emit(queued);
      return;
    }

    try {
      // Send the canonical (trimmed) values the repository persisted, so the
      // server and the local row agree and the reconcile upsert can't
      // reintroduce an untrimmed name.
      final server = await _remote.createHousehold(
        name: draft.household.name,
        clientRequestId: draft.household.id,
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
        // Not a failed attempt: the server did its part, and the key makes
        // the retry a replay (#131), so the op goes back uncounted.
        _logger.error(
          'Household reconcile failed after a successful server create; '
          'left queued',
          error: error,
          stackTrace: stackTrace,
        );
        await _releaseClaim(draft.syncQueueId);
        emit(queued);
      }
    } on HouseholdRemoteException catch (error) {
      _logger.warn(
        'Inline household sync failed (${error.runtimeType}); '
        'left queued for retry',
        error: error,
      );
      await _recordFailedAttempt(draft.syncQueueId, error);
      emit(queued);
    } on Object catch (error, stackTrace) {
      // Not a failed request but a client fault: an ArgumentError for a key
      // the server would reject (#131), or a bug. The household is written
      // and queued all the same, so surface it as pending rather than
      // stranding the UI in "submitting", and hand the op back uncounted.
      _logger.error(
        'Inline household sync threw before completing a request; left queued',
        error: error,
        stackTrace: stackTrace,
      );
      await _releaseClaim(draft.syncQueueId);
      emit(queued);
    }
  }

  /// Counts the failed send against the op's retries and keeps its error.
  ///
  /// Bookkeeping only: if it throws, the op stays claimed until its lease
  /// runs out, then any sender can take it. The household is queued either
  /// way, so the outcome shown is unchanged.
  Future<void> _recordFailedAttempt(
    String syncQueueId,
    HouseholdRemoteException error,
  ) async {
    try {
      await _syncQueue.markFailed(syncQueueId, error: error.toString());
    } on Object catch (writeError, stackTrace) {
      _logger.error(
        'Could not record the failed household send',
        error: writeError,
        stackTrace: stackTrace,
      );
    }
  }

  /// Hands the claimed op back without counting a retry. Same failure
  /// posture as [_recordFailedAttempt].
  Future<void> _releaseClaim(String syncQueueId) async {
    try {
      await _syncQueue.release(syncQueueId);
    } on Object catch (error, stackTrace) {
      _logger.error(
        'Could not release the queued household create',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
