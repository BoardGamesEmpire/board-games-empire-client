import 'package:equatable/equatable.dart';

/// Why an event edit was not saved, or not saved whole (#500).
enum EditEventFailure {
  /// The server could not be reached, or answered with something a later
  /// attempt can survive.
  offline,

  /// The server refused this user the edit.
  refused,

  /// The event no longer exists on the server.
  gone,

  /// The server did not accept the event's values.
  invalid,

  /// The server did not accept the rules' values.
  rulesInvalid,

  /// Anything else.
  unexpected,
}

/// Where the event edit page stands (#500).
sealed class EditEventState extends Equatable {
  const EditEventState();

  @override
  List<Object?> get props => [];
}

/// Nothing saved yet, or a failure the person has edited past.
final class EditEventEditing extends EditEventState {
  const EditEventEditing();
}

/// A save is on its way.
final class EditEventSaving extends EditEventState {
  const EditEventSaving();
}

/// The edit is saved. When nothing had [changed], nothing was sent, and the
/// page closes without saying the event was updated.
final class EditEventSaved extends EditEventState {
  const EditEventSaved({this.changed = true});

  final bool changed;

  @override
  List<Object?> get props => [changed];
}

/// The edit was not saved whole, for [reason]. The form keeps what was
/// typed, to fix or send again.
///
/// With [detailsSaved], the event's own changes were saved and the rules'
/// were not. The bloc then holds the saved event as its new starting point,
/// so a later save does not send those changes again.
final class EditEventFailed extends EditEventState {
  const EditEventFailed(this.reason, {this.detailsSaved = false});

  final EditEventFailure reason;
  final bool detailsSaved;

  @override
  List<Object?> get props => [reason, detailsSaved];
}
