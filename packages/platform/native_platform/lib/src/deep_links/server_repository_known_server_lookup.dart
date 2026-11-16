import 'package:app_shell/app_shell.dart';
import 'package:interfaces/repositories.dart';

/// [KnownServerLookup] over the MetaDB server registry (#10).
///
/// The MetaDB is the source of truth for which servers this device knows.
/// A link's `bgeServerId` is resolved to the registry's `ServerConfig.id`
/// via [ServerRepository.getServerByBgeId], independent of connection
/// state: a disconnected-but-registered server is still known. Connection
/// concerns (switching to a known-but-inactive server) belong to the
/// orchestrator, not this lookup (#82).
class ServerRepositoryKnownServerLookup implements KnownServerLookup {
  ServerRepositoryKnownServerLookup({required this._serverRepository});

  final ServerRepository _serverRepository;

  @override
  Future<String?> localServerIdFor(String bgeServerId) async =>
      (await _serverRepository.getServerByBgeId(bgeServerId))?.id;
}
