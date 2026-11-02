import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import 'add_to_collection_event.dart';
import 'add_to_collection_state.dart';

/// Drives the add sheet (#45): adds one platform game to the user's
/// collection, and says what is already there on the medium chosen.
///
/// ## The entry already there
///
/// Choosing a medium looks up the live entry for it
/// ([GameCollectionRepository.getCollectionEntry]), so the sheet can say what
/// the add makes: an add on a medium already owned raises its quantity. The
/// lookup reads live entries only, so an entry removed earlier reads as
/// absent and gets no note. Its add overwrites the old quantity.
///
/// A lookup answering after the medium changed again is dropped, so the
/// entry shown is always the one for the medium on screen. A failed lookup is
/// logged and shows no entry: the add itself still works, or fails on its
/// own.
///
/// ## The add
///
/// [GameCollectionRepository.addToCollection] writes the entry and queues it
/// for the server, and the bloc sends the queued op at once
/// ([SendQueuedOpNow.sendNow]), as every write that queues one does. Its
/// outcome is [AddToCollectionState.sync]. Whatever it is, the entry is in
/// the collection: a send that doesn't reach the server, or that waits
/// behind an earlier change to the entry, leaves the op for the drain.
///
/// A submit while one is running is ignored. A failed write is logged and
/// shown until the user edits the form. Nothing is thrown out of the bloc: a
/// session ending under the sheet makes its repository throw, and that reads
/// as a failed lookup or add.
///
/// The bloc doesn't validate what it is sent. The sheet's form does: a
/// medium, a quantity of 1 or more that the stored total can hold, a rating
/// from 1 to 10 or none, and a comment that is not blank or none.
class AddToCollectionBloc
    extends Bloc<AddToCollectionEvent, AddToCollectionState> {
  AddToCollectionBloc({
    required this._repository,
    required this._sender,
    required this.platformGameId,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.collection.add'),
       super(const AddToCollectionState()) {
    on<AddToCollectionMediumChanged>(_onMediumChanged);
    on<AddToCollectionSubmitted>(_onSubmitted);
    on<AddToCollectionFailureCleared>(_onFailureCleared);
  }

  /// The platform game the sheet adds.
  final String platformGameId;

  final GameCollectionRepository _repository;
  final SyncOperationSender _sender;
  final BgeLogger _logger;

  Future<void> _onMediumChanged(
    AddToCollectionMediumChanged event,
    Emitter<AddToCollectionState> emit,
  ) async {
    final medium = event.medium;
    emit(AddToCollectionState(medium: medium, status: state.status));

    final GameCollection? existing;
    try {
      existing = await _repository.getCollectionEntry(
        platformGameId: platformGameId,
        medium: medium,
      );
    } on Object catch (error, stackTrace) {
      return _logger.warn(
        'Looking up the entry already in the collection failed',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // A later choice's lookup owns the note now.
    if (existing == null || state.medium != medium) return;
    emit(
      AddToCollectionState(
        medium: medium,
        existing: existing,
        status: state.status,
        sync: state.sync,
      ),
    );
  }

  Future<void> _onSubmitted(
    AddToCollectionSubmitted event,
    Emitter<AddToCollectionState> emit,
  ) async {
    if (state.status == AddToCollectionStatus.submitting) return;
    emit(state.withStatus(AddToCollectionStatus.submitting));

    final ({
      GameCollection entry,
      String syncQueueId,
      AddToCollectionOperation operation,
    })
    added;
    try {
      added = await _repository.addToCollection(
        platformGameId: platformGameId,
        medium: event.medium,
        quantity: event.quantity,
        rating: event.rating,
        comment: event.comment,
      );
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Adding to the collection failed',
        error: error,
        stackTrace: stackTrace,
      );
      return emit(state.withStatus(AddToCollectionStatus.failed));
    }

    // From here the entry is written and queued, so every outcome is an add;
    // only `sync` varies.
    final delivery = await _sender.sendNow(
      added.syncQueueId,
      added.operation,
      onClaimFailed: (error, stackTrace) => _logger.error(
        'Could not claim the queued add; left queued',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    emit(
      state.withStatus(
        AddToCollectionStatus.added,
        sync: switch (delivery) {
          SyncDelivered() => AddToCollectionSync.synced,
          SyncParked() => AddToCollectionSync.refused,
          SyncNotClaimed() || SyncFailed() => AddToCollectionSync.queued,
        },
      ),
    );
  }

  void _onFailureCleared(
    AddToCollectionFailureCleared event,
    Emitter<AddToCollectionState> emit,
  ) {
    if (state.status == AddToCollectionStatus.failed) {
      emit(state.withStatus(AddToCollectionStatus.editing));
    }
  }
}
