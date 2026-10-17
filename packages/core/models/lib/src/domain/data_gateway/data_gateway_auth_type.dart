/// How the server authenticates to a DataGateway when it connects.
///
/// Mirrors the backend's `AuthType` enum (`prisma/models/auth/auth-type.prisma`
/// in `board-games-empire-backend`). Only [none] connects today: the backend's
/// credentials factory throws `NotImplementedException` for the other two, so
/// the client creates and edits DataGateways with [none] alone (#41).
enum DataGatewayAuthType {
  none,
  bearer,
  mutualTls,

  /// A name this client does not know. Shown, never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static DataGatewayAuthType fromWire(String name) => switch (name) {
    'None' => DataGatewayAuthType.none,
    'Bearer' => DataGatewayAuthType.bearer,
    'MutualTls' => DataGatewayAuthType.mutualTls,
    _ => DataGatewayAuthType.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    DataGatewayAuthType.none => 'None',
    DataGatewayAuthType.bearer => 'Bearer',
    DataGatewayAuthType.mutualTls => 'MutualTls',
    DataGatewayAuthType.unknown => throw StateError(
      'DataGatewayAuthType.unknown has no wire name',
    ),
  };
}
