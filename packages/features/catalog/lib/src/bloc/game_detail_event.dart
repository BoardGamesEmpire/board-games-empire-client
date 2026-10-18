import 'package:equatable/equatable.dart';

/// Events of `GameDetailBloc`.
sealed class GameDetailEvent extends Equatable {
  const GameDetailEvent();

  @override
  List<Object?> get props => [];
}

/// Read the game: on entry, and on a retry.
final class GameDetailLoadRequested extends GameDetailEvent {
  const GameDetailLoadRequested();
}
