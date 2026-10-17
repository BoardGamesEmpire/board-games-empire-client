import 'package:equatable/equatable.dart';

/// What kind of change a stuck op carries, which decides how the screen
/// describes it.
enum StuckSyncOpKind {
  addToCollection,
  updateCollection,
  removeFromCollection,
  createHousehold,

  /// A payload this build can't decode. It can only be discarded usefully:
  /// a retry is counted again without being sent.
  unreadable,
}

/// One op the server refused or that ran out of retries, as the
/// retry-or-discard screen lists it (#190).
///
/// It carries what the screen says about the op and nothing it must not:
/// never the error the queue recorded, which can hold server messages and
/// URLs.
final class StuckSyncOp extends Equatable {
  const StuckSyncOp({required this.entryId, required this.kind, this.subject});

  /// The queue entry, which [SyncRecovery.retry] and
  /// [SyncRecovery.discard] take.
  final String entryId;

  final StuckSyncOpKind kind;

  /// What the op names: the game's title for a collection op, the
  /// household's name for a create. Null when it can't be told, such as
  /// for a game the cache has no title for.
  final String? subject;

  @override
  List<Object?> get props => [entryId, kind, subject];
}
