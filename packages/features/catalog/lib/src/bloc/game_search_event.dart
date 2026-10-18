import 'package:equatable/equatable.dart';

import 'game_search_state.dart';

/// Events of `GameSearchBloc`.
sealed class GameSearchEvent extends Equatable {
  const GameSearchEvent();

  @override
  List<Object?> get props => [];
}

/// The search field's text changed. Debounced: only the last of a burst is
/// searched for.
final class GameSearchQueryChanged extends GameSearchEvent {
  const GameSearchQueryChanged(this.query);

  final String query;

  @override
  List<Object?> get props => [query];
}

/// The filter changed.
final class GameSearchFilterChanged extends GameSearchEvent {
  const GameSearchFilterChanged(this.filter);

  final GameSearchFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// The user asked for the current search again.
final class GameSearchRetryRequested extends GameSearchEvent {
  const GameSearchRetryRequested();
}

/// The DataGateways' names arrived. Not a user event: how the bloc's own
/// read of them reaches its handlers.
final class GameSearchSourceNamesLoaded extends GameSearchEvent {
  const GameSearchSourceNamesLoaded(this.names);

  /// Each DataGateway's name, by id.
  final Map<String, String> names;

  @override
  List<Object?> get props => [names];
}
