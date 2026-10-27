import 'package:equatable/equatable.dart';

/// Input to a user search (#455, #499).
sealed class UserSearchEvent extends Equatable {
  const UserSearchEvent();

  @override
  List<Object?> get props => [];
}

/// The search field now reads [query].
final class UserSearchQueryChanged extends UserSearchEvent {
  const UserSearchQueryChanged(this.query);

  final String query;

  @override
  List<Object?> get props => [query];
}
