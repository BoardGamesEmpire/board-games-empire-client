import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Events of `CreateEventBloc`.
sealed class CreateEventEvent extends Equatable {
  const CreateEventEvent();

  @override
  List<Object?> get props => [];
}

/// The user submitted the create form's [draft].
///
/// The form checks what it can, and the repository refuses the rest before
/// anything is written. After a refusal, [draft] is the form as the user has
/// edited it since, with the refused invitee taken off, say (#499).
final class CreateEventSubmitted extends CreateEventEvent {
  const CreateEventSubmitted(this.draft);

  final EventDraft draft;

  @override
  List<Object?> get props => [draft];
}

/// Takes down a `CreateEventRefused` or a `CreateEventFailure` once the user
/// edits the form it is about.
///
/// The screen sends it on every edit. It takes the message down and nothing
/// more: a refused create stays parked, for the next submit to discard
/// (#499).
final class CreateEventFailureCleared extends CreateEventEvent {
  const CreateEventFailureCleared();
}
