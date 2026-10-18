import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import 'data_gateway_list_event.dart';

/// What the DataGateway list screen is showing (#41).
sealed class DataGatewayListState extends Equatable {
  const DataGatewayListState();

  @override
  List<Object?> get props => [];
}

/// The list is being read from the server.
final class DataGatewayListLoading extends DataGatewayListState {
  const DataGatewayListLoading();
}

/// The server refused the read: the user's role may not see DataGateways.
final class DataGatewayListDenied extends DataGatewayListState {
  const DataGatewayListDenied();
}

/// The read failed for a reason that says nothing about access. Retryable.
final class DataGatewayListFailed extends DataGatewayListState {
  const DataGatewayListFailed();
}

/// The server's list, alphabetical by name. May be empty.
final class DataGatewayListReady extends DataGatewayListState {
  const DataGatewayListReady({
    required this.gateways,
    this.mayChange = true,
    this.busy = const {},
    this.outcome,
  });

  final List<DataGateway> gateways;

  /// Whether to offer add, edit, delete, connect and disconnect. False once
  /// the session has seen a change refused (#41).
  final bool mayChange;

  /// Ids of the rows with an action in flight.
  final Set<String> busy;

  /// What the last action answered, until the user dismisses it or starts
  /// another.
  final DataGatewayListOutcome? outcome;

  @override
  List<Object?> get props => [gateways, mayChange, busy, outcome];
}

/// How an action on a row ended.
enum DataGatewayActionResult {
  /// Done. For connect and disconnect, the server's attempt succeeded too.
  done,

  /// The server made the change, but could not connect to or disconnect from
  /// the DataGateway. A failed connect still leaves it enabled.
  attemptFailed,

  /// The user's role may not change DataGateways.
  refused,

  /// The DataGateway no longer exists.
  gone,

  /// The request got no answer that says anything, or the server refused the
  /// request itself.
  failed,
}

/// The last action's outcome, for the banner above the list.
final class DataGatewayListOutcome extends Equatable {
  const DataGatewayListOutcome({
    required this.action,
    required this.result,
    required this.name,
  });

  final DataGatewayRowAction action;
  final DataGatewayActionResult result;

  /// The DataGateway's name, as it was when the action started.
  final String name;

  @override
  List<Object?> get props => [action, result, name];
}
