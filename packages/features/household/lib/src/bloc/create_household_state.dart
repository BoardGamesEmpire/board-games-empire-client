import 'package:equatable/equatable.dart';

sealed class CreateHouseholdState extends Equatable {
  const CreateHouseholdState();

  @override
  List<Object?> get props => [];
}

final class CreateHouseholdInitial extends CreateHouseholdState {
  const CreateHouseholdInitial();
}

final class CreateHouseholdSubmitting extends CreateHouseholdState {
  const CreateHouseholdSubmitting();
}

/// What became of a create's inline sync.
enum CreateHouseholdSync {
  /// The server confirmed it.
  synced,

  /// It stays queued, and the household flagged `isLocalOnly`, until a
  /// later sync confirms it.
  queued,

  /// The server refused it as it stands (#190). It stays queued, but
  /// parked, so no later sync sends it: the user has to retry or discard it
  /// by hand.
  refused,
}

/// The household was created locally.
///
/// [householdId] is the canonical server id when [sync] is
/// [CreateHouseholdSync.synced], and the optimistic local id otherwise.
/// Either way the household exists and is visible in the user's list.
final class CreateHouseholdSuccess extends CreateHouseholdState {
  const CreateHouseholdSuccess({required this.householdId, required this.sync});

  final String householdId;
  final CreateHouseholdSync sync;

  @override
  List<Object?> get props => [householdId, sync];
}

/// The household could not be created locally (an unexpected error — the
/// form prevents the only expected local failure, a blank name). Server
/// rejections do not surface here: per the offline-first model they leave
/// the household queued ([CreateHouseholdSuccess] with
/// [CreateHouseholdSync.queued], or [CreateHouseholdSync.refused] when it
/// was parked).
final class CreateHouseholdFailure extends CreateHouseholdState {
  const CreateHouseholdFailure();
}
