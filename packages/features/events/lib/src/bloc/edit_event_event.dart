import 'package:equatable/equatable.dart';
import 'package:events/src/edit/event_edit_controls.dart';

/// Input to the event edit page (#500).
sealed class EditEventEvent extends Equatable {
  const EditEventEvent();

  @override
  List<Object?> get props => [];
}

/// Save the form as it stands.
///
/// The values arrive as the form holds them, already trimmed. The bloc works
/// out what changed on the event and on its rules.
final class EditEventSubmitted extends EditEventEvent {
  const EditEventSubmitted(this.values);

  final EventEditValues values;

  @override
  List<Object?> get props => [values];
}

/// The person changed the form. A failure on show describes the values being
/// replaced, so it goes.
final class EditEventEdited extends EditEventEvent {
  const EditEventEdited();
}
