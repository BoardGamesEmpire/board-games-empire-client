import 'package:equatable/equatable.dart';

/// Events for `ServerOnboardingBloc` (#36).
sealed class ServerOnboardingEvent extends Equatable {
  const ServerOnboardingEvent();

  @override
  List<Object?> get props => const [];
}

/// The user submitted the add-server form.
final class ServerOnboardingSubmitted extends ServerOnboardingEvent {
  const ServerOnboardingSubmitted({required this.url, this.alias});

  /// Raw user input — normalization/validation is the bloc's first step,
  /// so the full policy is covered by bloc tests.
  final String url;

  /// Optional display-name alias; blank/null falls back to the server's
  /// advertised `name` from the discovery document.
  final String? alias;

  @override
  List<Object?> get props => [url, alias];
}

/// The failure on screen no longer describes the current input.
///
/// Dispatched by the form when the user edits the address, and when a
/// submit is rejected locally without ever leaving the widget layer. Named
/// for the transition rather than either trigger, since both mean the same
/// thing to the bloc and neither is "the input was rejected".
///
/// Carries no payload: it asserts nothing about the input, it only retires
/// a stale failure. Without it the earlier banner stays up while the user
/// types its replacement, or sits above a new inline error contradicting
/// it.
final class ServerOnboardingFailureCleared extends ServerOnboardingEvent {
  const ServerOnboardingFailureCleared();
}
