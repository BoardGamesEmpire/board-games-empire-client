import 'package:flutter/foundation.dart';
import 'package:models/domain.dart';

/// What the server manager shows (#134).
@immutable
sealed class ServerListState {
  const ServerListState();
}

/// The registry hasn't answered yet.
final class ServerListLoading extends ServerListState {
  const ServerListLoading();
}

/// Every registered server, in the registry's order, with its state.
final class ServerListReady extends ServerListState {
  const ServerListReady({required this.rows, this.switchingTo});

  final List<ServerListRow> rows;

  /// The server a pick is making active, while it runs.
  final String? switchingTo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerListReady &&
          other.switchingTo == switchingTo &&
          listEquals(other.rows, rows);

  @override
  int get hashCode => Object.hash(Object.hashAll(rows), switchingTo);

  @override
  String toString() =>
      'ServerListReady(rows: $rows, switchingTo: $switchingTo)';
}

/// The registry couldn't be read.
final class ServerListFailed extends ServerListState {
  const ServerListFailed(this.error);

  final Object error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerListFailed && other.error == error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'ServerListFailed($error)';
}

/// Where a registered server stands with the orchestrator.
enum ServerRowState {
  /// The active server.
  inUse,

  /// Connected but not active: backgrounding or monitoring.
  dormant,

  /// Registered, with no context.
  notConnected,
}

/// One registered server and its state.
@immutable
class ServerListRow {
  const ServerListRow({required this.server, required this.state});

  final ServerConfig server;
  final ServerRowState state;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerListRow && other.server == server && other.state == state;

  @override
  int get hashCode => Object.hash(server, state);

  @override
  String toString() => 'ServerListRow(${server.id}, $state)';
}
