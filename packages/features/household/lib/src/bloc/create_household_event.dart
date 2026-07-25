import 'package:equatable/equatable.dart';

sealed class CreateHouseholdEvent extends Equatable {
  const CreateHouseholdEvent();

  @override
  List<Object?> get props => [];
}

/// The user submitted the create-household form.
///
/// [name] is required and already non-blank (the form validates it); the
/// repository trims it. [description] is optional — `null` or empty means
/// "no description".
final class CreateHouseholdSubmitted extends CreateHouseholdEvent {
  const CreateHouseholdSubmitted({required this.name, this.description});

  final String name;
  final String? description;

  @override
  List<Object?> get props => [name, description];
}
