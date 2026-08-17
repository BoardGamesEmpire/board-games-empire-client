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

/// Retires a [CreateHouseholdFailure] once the user edits the form it
/// complains about.
///
/// The failure surface is an inline banner bound to bloc state (#191), so
/// it does not fade the way the SnackBar it replaced did. Without this, a
/// user fixing the name kept reading a complaint about the value they had
/// just replaced.
final class CreateHouseholdFailureCleared extends CreateHouseholdEvent {
  const CreateHouseholdFailureCleared();
}
