import 'package:app_shell/app_shell.dart';
import 'package:interfaces/repositories.dart';

/// [KnownServerLookup] over the MetaDB server registry (#10).
///
/// The MetaDB is the source of truth for which servers this device knows
/// (#10 decision) — *known* is strictly registry membership via
/// [ServerRepository.getServer], independent of connection state: a
/// disconnected-but-registered server is still known. Connection concerns
/// (switching to a known-but-inactive server) belong to the consumption
/// scope (#82) and the orchestrator, not this lookup.
class ServerRepositoryKnownServerLookup implements KnownServerLookup {
  ServerRepositoryKnownServerLookup({
    required ServerRepository serverRepository,
  }) : _serverRepository = serverRepository;

  final ServerRepository _serverRepository;

  @override
  Future<bool> isKnownServer(String serverId) async =>
      await _serverRepository.getServer(serverId) != null;
}
