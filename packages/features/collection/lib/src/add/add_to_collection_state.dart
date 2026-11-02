import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

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

/// What became of an add's immediate send (#45).
enum AddToCollectionSync {
  /// The server has it.
  synced,

  /// It stays queued: the send didn't reach the server, or an earlier
  /// change to the entry is still waiting. The drain sends it later on
  /// native; web has no drain yet (#447), so there it waits.
  queued,

  /// The server refused it. It is kept on this device and won't be sent
  /// again on its own: the user retries or discards it where changes that
  /// couldn't sync are listed (#190).
  refused,
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
  final AddToCollectionSync? sync;

  /// This state at [next], keeping the medium and the entry found. [sync]
  /// goes with [AddToCollectionStatus.added].
  AddToCollectionState withStatus(
    AddToCollectionStatus next, {
    AddToCollectionSync? sync,
  }) => AddToCollectionState(
    medium: medium,
    existing: existing,
    status: next,
    sync: sync,
  );

  @override
  List<Object?> get props => [medium, existing, status, sync];
}
