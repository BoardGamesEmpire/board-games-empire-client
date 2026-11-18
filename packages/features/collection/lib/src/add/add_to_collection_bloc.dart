import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:game_collection/src/add/add_to_collection_event.dart';
import 'package:game_collection/src/add/add_to_collection_state.dart';
import 'package:game_collection/src/sync/collection_sync.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

/// Drives the add sheet (#45): adds a game to the user's collection on the
/// platform game chosen (#708), and says what is already there on the
/// platform and medium chosen.
///
/// The platform travels in the events rather than in the bloc, since the
/// sheet chooses it: [AddToCollectionChoiceChanged] says what is chosen, and
/// [AddToCollectionSubmitted] what to add.
///
/// ## The entry already there
///
/// Choosing a platform and a medium looks up the live entry for them
/// ([GameCollectionRepository.getCollectionEntry]), so the sheet can say what
/// the add makes: an add on a medium already owned raises its quantity. The
/// sheet offers only the mediums free when it opened, so this is the rare
/// case of one added since (#708). The lookup reads live entries only, so an
/// entry removed earlier reads as absent and gets no note. Its add
/// overwrites the old quantity. A choice with no medium has nothing to look
/// up, and clears the entry shown.
///
/// A lookup answering after any later choice is dropped (#773), so the entry
/// shown is always the one for the choice on screen. A failed lookup is
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
/// platform game and a medium, a quantity of 1 or more that the stored total
/// can hold, a rating from 1 to 10 or none, and a comment that is not blank
/// or none. The form's total counts the lookup's entry, which may not have
/// answered yet, or may be older than the entry stored, so the repository
/// checks the total again. An add it refuses at the limit ends
/// [AddToCollectionStatus.quantityTooMany], not a failure, and the entry is
/// looked up again, so the copies the form counts are the ones the refusal
/// counted (#676).
class AddToCollectionBloc
    extends Bloc<AddToCollectionEvent, AddToCollectionState> {
  AddToCollectionBloc({
    required this._repository,
    required this._sender,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.collection.add'),
       super(const AddToCollectionState()) {
    on<AddToCollectionChoiceChanged>(_onChoiceChanged);
    on<AddToCollectionSubmitted>(_onSubmitted);
    on<AddToCollectionFailureCleared>(_onFailureCleared);
  }

  final GameCollectionRepository _repository;
  final SyncOperationSender _sender;
  final BgeLogger _logger;

  /// The latest choice's number; a lookup answers only while it is still the
  /// latest (#773).
  int _lookup = 0;

  Future<void> _onChoiceChanged(
    AddToCollectionChoiceChanged event,
    Emitter<AddToCollectionState> emit,
  ) async {
    // Taken before the early return, so a cleared medium retires older lookups.
    final lookup = ++_lookup;
    final platformGameId = event.platformGameId;
    final medium = event.medium;
    emit(
      AddToCollectionState(
        platformGameId: platformGameId,
        medium: medium,
        status: state.status,
      ),
    );
    if (medium == null) return;
    await _lookUp(lookup, platformGameId, medium, emit);
  }

  /// Shows the live entry for [platformGameId] on [medium], unless a later
  /// choice took a number past [lookup] meanwhile.
  Future<void> _lookUp(
    int lookup,
    String platformGameId,
    GameMedium medium,
    Emitter<AddToCollectionState> emit,
  ) async {
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

    // Any later choice owns the note now, even one back to this same pair:
    // comparing the pair would let this older answer overwrite its newer one
    // (#773).
    if (lookup != _lookup) return;
    // A choice already shows no entry, but the lookup after a refusal may
    // find the one shown removed since, and must clear it (#676).
    if (existing == null && state.existing == null) return;
    emit(
      AddToCollectionState(
        platformGameId: platformGameId,
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
        platformGameId: event.platformGameId,
        medium: event.medium,
        quantity: event.quantity,
        rating: event.rating,
        comment: event.comment,
      );
    } on CollectionQuantityLimitExceeded catch (error) {
      // Not a failure: the copies field says so, and the add can be sent
      // again once they are changed (#676).
      _logger.info(
        'The add passes the most copies an entry holds',
        error: error,
      );
      emit(state.withStatus(AddToCollectionStatus.quantityTooMany));
      // The entry the form counted hadn't answered, or is older than the one
      // the refusal counted. Read again, the copies' bound and the note count
      // what is stored, so a second submit isn't refused the same way.
      return _lookUp(++_lookup, event.platformGameId, event.medium, emit);
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
        sync: CollectionSync.of(delivery),
      ),
    );
  }

  void _onFailureCleared(
    AddToCollectionFailureCleared event,
    Emitter<AddToCollectionState> emit,
  ) {
    if (state.status == AddToCollectionStatus.failed ||
        state.status == AddToCollectionStatus.quantityTooMany) {
      emit(state.withStatus(AddToCollectionStatus.editing));
    }
  }
}
