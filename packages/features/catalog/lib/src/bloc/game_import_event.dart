import 'package:equatable/equatable.dart';

/// Events of `GameImportBloc`.
sealed class GameImportEvent extends Equatable {
  const GameImportEvent();

  @override
  List<Object?> get props => [];
}

/// Start the import: on entry, and to try again after it failed.
final class GameImportRequested extends GameImportEvent {
  const GameImportRequested();
}

/// Poll the same import again, once the deadline has passed with no outcome.
final class GameImportCheckAgainRequested extends GameImportEvent {
  const GameImportCheckAgainRequested();
}
