import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
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
/// 2. A best-effort inline send of the op as queued, through
///    [SyncOperationSender.deliver], the one delivery path the queue drain
///    takes too (#121). It claims the queued op first, so this send and a
///    drain can't both deliver it (#430), and keys the create by the
///    optimistic row's id, the op's `localId`, so a send whose response is
///    lost cannot become a second household on the retry (#131).
///    - delivered → the row now carries the server's id and the op is
///      closed → [CreateHouseholdSync.synced].
///    - parked → the server refused it, and no drain will send it again →
///      [CreateHouseholdSync.refused] (#190).
///    - anything else → the household stays queued, and the create still
///      succeeded locally → [CreateHouseholdSync.queued]. What became of the
///      queue entry (held by another sender, counted or handed back) is the
///      sender's to record, and the drain's to retry.
///
/// A delivery that throws means the claim itself failed and nothing was
/// sent, which also leaves the household queued.
class CreateHouseholdBloc
    extends Bloc<CreateHouseholdEvent, CreateHouseholdState> {
  CreateHouseholdBloc({
    required HouseholdRepository repository,
    required this._sender,
    BgeLogger? logger,
  }) : _repo = repository,
       _logger = logger ?? BgeLogger('bge.household.create'),
       super(const CreateHouseholdInitial()) {
    on<CreateHouseholdSubmitted>(_onSubmitted);
    on<CreateHouseholdFailureCleared>(_onFailureCleared);
  }

  final HouseholdRepository _repo;
  final SyncOperationSender _sender;
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

    final ({
      Household household,
      String syncQueueId,
      CreateHouseholdOperation operation,
    })
    draft;
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
    // is a success; only `sync` varies.
    final queued = CreateHouseholdSuccess(
      householdId: draft.household.id,
      sync: CreateHouseholdSync.queued,
    );

    final SyncDelivery delivery;
    try {
      // The op exactly as the repository queued it, so this send carries
      // what a drain's retry would: the trimmed name, and the fields the row
      // has no column for.
      delivery = await _sender.deliver(draft.syncQueueId, draft.operation);
    } on Object catch (error, stackTrace) {
      _logger.error(
        'Could not claim the queued household create; left queued',
        error: error,
        stackTrace: stackTrace,
      );
      emit(queued);
      return;
    }

    switch (delivery) {
      case SyncDelivered(:final householdId):
        emit(
          CreateHouseholdSuccess(
            householdId: householdId ?? draft.household.id,
            sync: CreateHouseholdSync.synced,
          ),
        );
      case SyncParked():
        emit(
          CreateHouseholdSuccess(
            householdId: draft.household.id,
            sync: CreateHouseholdSync.refused,
          ),
        );
      case SyncNotClaimed() || SyncFailed():
        emit(queued);
    }
  }
}
