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
