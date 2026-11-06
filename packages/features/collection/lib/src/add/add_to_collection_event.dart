import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the add sheet tells its bloc (#45).
sealed class AddToCollectionEvent extends Equatable {
  const AddToCollectionEvent();

  @override
  List<Object?> get props => [];
}

/// The sheet's platform and medium are now [platformGameId] and [medium],
/// so the bloc looks for the entry already in the collection on them (#708).
///
/// Sent when the user picks either, and by the sheet for the start it
/// chooses itself. A null [medium] is no choice yet: a platform with no type
/// stored starts on none.
final class AddToCollectionChoiceChanged extends AddToCollectionEvent {
  const AddToCollectionChoiceChanged({
    required this.platformGameId,
    this.medium,
  });

  final String platformGameId;
  final GameMedium? medium;

  @override
  List<Object?> get props => [platformGameId, medium];
}

/// The user submitted the sheet's form, which has validated it: a platform
/// game and a medium are chosen, [quantity] is at least 1, [rating] is null
/// or 1 to 10, and [comment] is null or not blank.
final class AddToCollectionSubmitted extends AddToCollectionEvent {
  const AddToCollectionSubmitted({
    required this.platformGameId,
    required this.medium,
    required this.quantity,
    this.rating,
    this.comment,
  });

  /// The platform game the add is on, as the form holds it at the submit.
  final String platformGameId;
  final GameMedium medium;
  final int quantity;
  final int? rating;
  final String? comment;

  @override
  List<Object?> get props => [
    platformGameId,
    medium,
    quantity,
    rating,
    comment,
  ];
}

/// The user changed the form, which retires a failure it showed: it was
/// about the values they have just replaced. Sent on every change, and kept
/// only while a failure shows (STYLE_GUIDE, "Error and outcome surfaces").
final class AddToCollectionFailureCleared extends AddToCollectionEvent {
  const AddToCollectionFailureCleared();
}
