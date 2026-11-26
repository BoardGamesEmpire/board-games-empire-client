import 'package:equatable/equatable.dart';

/// Input to a key's own page (#1028).
sealed class ApiKeyDetailEvent extends Equatable {
  const ApiKeyDetailEvent();

  @override
  List<Object?> get props => [];
}

/// Read the key and the permissions the user may grant from the server.
final class ApiKeyDetailRequested extends ApiKeyDetailEvent {
  const ApiKeyDetailRequested();
}

/// Turn the key on or off, straight away: re-enabling a key asks for nothing.
final class ApiKeyEnabledChanged extends ApiKeyDetailEvent {
  const ApiKeyEnabledChanged({required this.enabled});

  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

/// Delete the key. The page has asked the user already.
final class ApiKeyDeleteRequested extends ApiKeyDetailEvent {
  const ApiKeyDeleteRequested();
}

/// Retire the last write's outcome.
final class ApiKeyDetailOutcomeCleared extends ApiKeyDetailEvent {
  const ApiKeyDetailOutcomeCleared();
}
