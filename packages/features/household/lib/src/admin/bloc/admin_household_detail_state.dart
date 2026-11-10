import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the staff household detail is showing (#685).
sealed class AdminHouseholdDetailState extends Equatable {
  const AdminHouseholdDetailState();

  @override
  List<Object?> get props => const [];
}

/// The household is being read from the server.
final class AdminHouseholdDetailLoading extends AdminHouseholdDetailState {
  const AdminHouseholdDetailLoading();
}

/// The household, as the server gave it.
final class AdminHouseholdDetailReady extends AdminHouseholdDetailState {
  const AdminHouseholdDetailReady(this.household);

  final AdminHouseholdDetail household;

  @override
  List<Object?> get props => [household];
}

/// The server answered that the household is gone or deleted (a 404).
final class AdminHouseholdDetailGone extends AdminHouseholdDetailState {
  const AdminHouseholdDetailGone();
}

/// The server refused the read (a 403).
final class AdminHouseholdDetailRefused extends AdminHouseholdDetailState {
  const AdminHouseholdDetailRefused();
}

/// The read got no answer that says anything about the household, or the
/// server refused the request itself. It can be tried again.
final class AdminHouseholdDetailFailed extends AdminHouseholdDetailState {
  const AdminHouseholdDetailFailed();
}
