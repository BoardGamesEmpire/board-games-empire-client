import 'package:equatable/equatable.dart';

/// Events of `GameBrowseBloc`.
sealed class GameBrowseEvent extends Equatable {
  const GameBrowseEvent();

  @override
  List<Object?> get props => [];
}

/// Read the catalog from its first page: on entry, and on a retry.
final class GameBrowseLoadRequested extends GameBrowseEvent {
  const GameBrowseLoadRequested();
}

/// Read the next page onto the end of the list.
final class GameBrowseMoreRequested extends GameBrowseEvent {
  const GameBrowseMoreRequested();
}
