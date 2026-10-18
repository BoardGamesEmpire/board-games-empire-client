import 'package:freezed_annotation/freezed_annotation.dart';

import 'data_gateway.dart';

part 'data_gateway_change_result.freezed.dart';

/// Which way a [DataGatewayConnectionAttempt] went.
enum DataGatewayConnectionAction { connect, disconnect }

/// The server's attempt to connect to, or disconnect from, a DataGateway.
///
/// Reported once, on the response to the action that caused it, and stored
/// nowhere: the server keeps only `enabled` (#41). A failed connect still
/// leaves the DataGateway enabled, because the server sets that first.
@freezed
abstract class DataGatewayConnectionAttempt
    with _$DataGatewayConnectionAttempt {
  const factory DataGatewayConnectionAttempt({
    required DataGatewayConnectionAction action,
    required bool succeeded,
  }) = _DataGatewayConnectionAttempt;
}

/// What a create, update, delete, connect or disconnect answered (#41).
@freezed
abstract class DataGatewayChangeResult with _$DataGatewayChangeResult {
  const factory DataGatewayChangeResult({
    /// The row as the server left it. After a delete, the deleted row.
    required DataGateway dataGateway,

    /// Null when the server did not try. A create tries to connect when the
    /// new DataGateway is enabled, a delete tries to disconnect when the
    /// deleted one was, and an update that leaves `enabled` alone never
    /// tries.
    DataGatewayConnectionAttempt? connectionAttempt,
  }) = _DataGatewayChangeResult;
}
