import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../sync/collection_sync.dart';

/// Where an add stands.
enum AddToCollectionStatus {
  /// The form is open for changes.
  editing,

  /// The add is being written and sent. Another submit is ignored
  /// meanwhile.
  submitting,

  /// The add failed and nothing was saved. The form keeps what was typed.
  failed,

  /// The game is in the collection: see [AddToCollectionState.sync] for
  /// whether the server has it.
  added,
}

/// What the add sheet is showing (#45).
final class AddToCollectionState extends Equatable {
  const AddToCollectionState({
    this.medium,
    this.existing,
    this.status = AddToCollectionStatus.editing,
    this.sync,
  });

  /// The medium chosen, or null until one is.
  final GameMedium? medium;

  /// The live entry already in the collection for [medium], or null: none
  /// is, the lookup hasn't answered, or it failed. An add on it raises its
  /// quantity.
  final GameCollection? existing;

  final AddToCollectionStatus status;

  /// What became of the add's send, set with [AddToCollectionStatus.added].
  final CollectionSync? sync;

  /// This state at [next], keeping the medium and the entry found. [sync]
  /// goes with [AddToCollectionStatus.added].
  AddToCollectionState withStatus(
    AddToCollectionStatus next, {
    CollectionSync? sync,
  }) => AddToCollectionState(
    medium: medium,
    existing: existing,
    status: next,
    sync: sync,
  );

  @override
  List<Object?> get props => [medium, existing, status, sync];
}
