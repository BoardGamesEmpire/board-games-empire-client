import 'package:api_keys/src/list/api_key_list_state.dart';
import 'package:equatable/equatable.dart';

/// Input to the key list (#1028).
sealed class ApiKeyListEvent extends Equatable {
  const ApiKeyListEvent();

  @override
  List<Object?> get props => [];
}

/// Read page 1 and the grantable permissions from the server, and show them
/// in place of what was loaded. The rows on screen stay while it runs.
final class ApiKeyListRequested extends ApiKeyListEvent {
  const ApiKeyListRequested();
}

/// Read the next page and add it below the rows loaded so far.
final class ApiKeyListMoreRequested extends ApiKeyListEvent {
  const ApiKeyListMoreRequested();
}

/// Show only the loaded keys [filter] lets through. Reads nothing.
final class ApiKeyListFilterChanged extends ApiKeyListEvent {
  const ApiKeyListFilterChanged(this.filter);

  final ApiKeyStatusFilter filter;

  @override
  List<Object?> get props => [filter];
}
