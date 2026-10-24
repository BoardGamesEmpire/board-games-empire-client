import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Input to the household edit form (#476).
sealed class EditHouseholdEvent extends Equatable {
  const EditHouseholdEvent();

  @override
  List<Object?> get props => [];
}

/// Save the form as it stands.
///
/// The values arrive as the form holds them, already trimmed: [description]
/// is null when the field is blank, and [memberInvitePolicy] is null when no
/// option is chosen. The bloc works out what changed.
final class EditHouseholdSubmitted extends EditHouseholdEvent {
  const EditHouseholdSubmitted({
    required this.name,
    this.description,
    this.memberInvitePolicy,
  });

  final String name;
  final String? description;
  final MemberInvitePolicy? memberInvitePolicy;

  @override
  List<Object?> get props => [name, description, memberInvitePolicy];
}

/// The person changed the form. A failure on show describes the values
/// being replaced, so it goes.
final class EditHouseholdEdited extends EditHouseholdEvent {
  const EditHouseholdEdited();
}
