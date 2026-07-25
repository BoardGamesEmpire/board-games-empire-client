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

/// The household was created locally.
///
/// [householdId] is the canonical server id when [pendingSync] is `false`
/// (the inline sync confirmed it), or the optimistic local id when
/// [pendingSync] is `true` (the server hasn't confirmed yet — it stays
/// queued and the household is flagged `isLocalOnly` until a later sync).
/// Either way the household exists and is visible in the user's list.
final class CreateHouseholdSuccess extends CreateHouseholdState {
  const CreateHouseholdSuccess({
    required this.householdId,
    required this.pendingSync,
  });

  final String householdId;
  final bool pendingSync;

  @override
  List<Object?> get props => [householdId, pendingSync];
}

/// The household could not be created locally (an unexpected error — the
/// form prevents the only expected local failure, a blank name). Server
/// rejections do not surface here: per the offline-first model they leave
/// the household queued ([CreateHouseholdSuccess] with `pendingSync`).
final class CreateHouseholdFailure extends CreateHouseholdState {
  const CreateHouseholdFailure();
}
