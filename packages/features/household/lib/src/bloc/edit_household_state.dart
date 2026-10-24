import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Why a household edit was not saved (#476).
enum EditHouseholdFailure {
  /// The server could not be reached, or answered with something a later
  /// attempt can survive.
  offline,

  /// The household no longer exists on the server.
  gone,

  /// The server refused this user the edit.
  refused,

  /// The server did not accept the values.
  invalid,

  /// Anything else.
  unexpected,
}

/// Where the household edit form stands (#476).
sealed class EditHouseholdState extends Equatable {
  const EditHouseholdState();

  @override
  List<Object?> get props => [];
}

/// Nothing saved yet.
final class EditHouseholdEditing extends EditHouseholdState {
  const EditHouseholdEditing();
}

/// The edit is on its way.
final class EditHouseholdSaving extends EditHouseholdState {
  const EditHouseholdSaving();
}

/// The edit is saved, and [household] is the server's answer. When nothing
/// had [changed], nothing was sent, and [household] is the one the form
/// opened with.
final class EditHouseholdSaved extends EditHouseholdState {
  const EditHouseholdSaved(this.household, {this.changed = true});

  final Household household;

  /// Whether anything was sent. A save that changed nothing closes the form
  /// without saying the household was updated.
  final bool changed;

  @override
  List<Object?> get props => [household, changed];
}

/// The edit was not saved, for [reason]. The form keeps what was typed, to
/// fix or send again.
final class EditHouseholdFailed extends EditHouseholdState {
  const EditHouseholdFailed(this.reason);

  final EditHouseholdFailure reason;

  @override
  List<Object?> get props => [reason];
}
