import 'package:equatable/equatable.dart';

/// An action on one row of the DataGateway list.
enum DataGatewayRowAction { connect, disconnect, delete }

/// Events of `DataGatewayListBloc`.
sealed class DataGatewayListEvent extends Equatable {
  const DataGatewayListEvent();

  @override
  List<Object?> get props => [];
}

/// Read the list from the server: on opening, on retry, and on returning
/// from the add or edit form.
final class DataGatewayListLoadRequested extends DataGatewayListEvent {
  const DataGatewayListLoadRequested();
}

/// The user asked for [action] on the DataGateway with [id]. A delete has
/// already been confirmed by then.
final class DataGatewayListActionRequested extends DataGatewayListEvent {
  const DataGatewayListActionRequested(this.action, this.id);

  final DataGatewayRowAction action;
  final String id;

  @override
  List<Object?> get props => [action, id];
}

/// The user closed the banner reporting the last action.
final class DataGatewayListOutcomeDismissed extends DataGatewayListEvent {
  const DataGatewayListOutcomeDismissed();
}

/// The session's access changed under the screen, because another screen
/// learned something. Internal.
final class DataGatewayListAccessChanged extends DataGatewayListEvent {
  const DataGatewayListAccessChanged();
}
