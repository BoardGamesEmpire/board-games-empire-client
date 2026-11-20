import 'package:meta/meta.dart';

/// The game whose expansions `GamesRemoteDataSource.fetchExpansions` asks
/// for (#713): a search result still at its DataGateway, or a game the
/// server holds.
@immutable
sealed class GameExpansionsTarget {
  const GameExpansionsTarget();

  /// A DataGateway result, named by its DataGateway and External ID.
  const factory GameExpansionsTarget.dataGateway({
    required String gatewayId,
    required String externalId,
  }) = DataGatewayExpansionsTarget;

  /// A game on this server, named by its id.
  const factory GameExpansionsTarget.game(String gameId) =
      ServerGameExpansionsTarget;
}

/// See [GameExpansionsTarget.dataGateway].
final class DataGatewayExpansionsTarget extends GameExpansionsTarget {
  const DataGatewayExpansionsTarget({
    required this.gatewayId,
    required this.externalId,
  });

  final String gatewayId;
  final String externalId;

  @override
  bool operator ==(Object other) =>
      other is DataGatewayExpansionsTarget &&
      other.gatewayId == gatewayId &&
      other.externalId == externalId;

  @override
  int get hashCode => Object.hash(gatewayId, externalId);

  @override
  String toString() =>
      'GameExpansionsTarget.dataGateway($gatewayId/$externalId)';
}

/// See [GameExpansionsTarget.game].
final class ServerGameExpansionsTarget extends GameExpansionsTarget {
  const ServerGameExpansionsTarget(this.gameId);

  final String gameId;

  @override
  bool operator ==(Object other) =>
      other is ServerGameExpansionsTarget && other.gameId == gameId;

  @override
  int get hashCode => gameId.hashCode;

  @override
  String toString() => 'GameExpansionsTarget.game($gameId)';
}
