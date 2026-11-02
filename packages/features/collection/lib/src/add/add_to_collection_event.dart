import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the add sheet tells its bloc (#45).
sealed class AddToCollectionEvent extends Equatable {
  const AddToCollectionEvent();

  @override
  List<Object?> get props => [];
}

/// The user chose [medium], so the bloc looks for the entry already in the
/// collection on it.
final class AddToCollectionMediumChanged extends AddToCollectionEvent {
  const AddToCollectionMediumChanged(this.medium);

  final GameMedium medium;

  @override
  List<Object?> get props => [medium];
}

/// The user submitted the sheet's form, which has validated it: [quantity]
/// is at least 1, [rating] is null or 1 to 10, and [comment] is null or
/// not blank.
final class AddToCollectionSubmitted extends AddToCollectionEvent {
  const AddToCollectionSubmitted({
    required this.medium,
    required this.quantity,
    this.rating,
    this.comment,
  });

  final GameMedium medium;
  final int quantity;
  final int? rating;
  final String? comment;

  @override
  List<Object?> get props => [medium, quantity, rating, comment];
}

/// The user changed the form, which retires a failure it showed: it was
/// about the values they have just replaced. Sent on every change, and kept
/// only while a failure shows (STYLE_GUIDE, "Error and outcome surfaces").
final class AddToCollectionFailureCleared extends AddToCollectionEvent {
  const AddToCollectionFailureCleared();
}
