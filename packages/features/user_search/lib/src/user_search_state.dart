import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What a user search is showing (#455, #499).
sealed class UserSearchState extends Equatable {
  const UserSearchState();

  @override
  List<Object?> get props => [];
}

/// No search: the query is too short to send.
final class UserSearchIdle extends UserSearchState {
  const UserSearchIdle();
}

/// The server is being asked.
final class UserSearchLoading extends UserSearchState {
  const UserSearchLoading();
}

/// Who matched. May be empty.
final class UserSearchResults extends UserSearchState {
  const UserSearchResults(this.users);

  final List<UserSummary> users;

  @override
  List<Object?> get props => [users];
}

/// The search got no usable answer. Typing again tries again.
final class UserSearchFailed extends UserSearchState {
  const UserSearchFailed();
}
