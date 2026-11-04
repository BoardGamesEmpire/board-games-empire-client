import 'package:equatable/equatable.dart';

/// Events of `DataGatewayDetailBloc`.
sealed class DataGatewayDetailEvent extends Equatable {
  const DataGatewayDetailEvent();

  @override
  List<Object?> get props => [];
}

/// Read the row from the server: on opening, on retry, on a refresh, and on
/// coming back into view.
final class DataGatewayDetailLoadRequested extends DataGatewayDetailEvent {
  const DataGatewayDetailLoadRequested();
}

/// The user asked to interview the DataGateway again.
final class DataGatewayDetailInterviewRequested extends DataGatewayDetailEvent {
  const DataGatewayDetailInterviewRequested();
}

/// The user switched [capability] on or off. [capability] is the server's own
/// spelling, whether or not this client can label it (#457).
final class DataGatewayDetailCapabilitySwitched extends DataGatewayDetailEvent {
  const DataGatewayDetailCapabilitySwitched(
    this.capability, {
    required this.on,
  });

  final String capability;

  /// Whether the user wants it on: the server routes it.
  final bool on;

  @override
  List<Object?> get props => [capability, on];
}

/// The user closed the banner reporting the last action.
final class DataGatewayDetailOutcomeDismissed extends DataGatewayDetailEvent {
  const DataGatewayDetailOutcomeDismissed();
}

/// The caller's access changed under the screen: the session kept a new
/// answer (#456). Internal.
final class DataGatewayDetailAccessChanged extends DataGatewayDetailEvent {
  const DataGatewayDetailAccessChanged();
}
