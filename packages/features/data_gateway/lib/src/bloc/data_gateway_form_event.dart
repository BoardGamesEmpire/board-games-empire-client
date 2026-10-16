import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Events of `DataGatewayFormBloc`.
sealed class DataGatewayFormEvent extends Equatable {
  const DataGatewayFormEvent();

  @override
  List<Object?> get props => [];
}

/// The form opened, or the user asked to retry reading the row it edits.
final class DataGatewayFormStarted extends DataGatewayFormEvent {
  const DataGatewayFormStarted();
}

/// The user submitted valid values.
final class DataGatewayFormSubmitted extends DataGatewayFormEvent {
  const DataGatewayFormSubmitted(this.input);

  final DataGatewayInput input;

  @override
  List<Object?> get props => [input];
}

/// The user edited the form, which retires a failure it showed: the banner
/// describes the values being replaced (#191).
final class DataGatewayFormFailureCleared extends DataGatewayFormEvent {
  const DataGatewayFormFailureCleared();
}
