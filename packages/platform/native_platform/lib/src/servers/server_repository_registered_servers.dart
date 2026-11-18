import 'package:app_shell/app_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

/// [RegisteredServers] over the MetaDB server registry (#134).
///
/// Lists every registered server via [ServerRepository.watchServers],
/// independent of connection state. Drift's `watch` re-emits on any write to
/// the table, equal result or not, so a repeat of the last list is dropped
/// here rather than redrawing the manager for nothing.
class ServerRepositoryRegisteredServers implements RegisteredServers {
  ServerRepositoryRegisteredServers({required this._serverRepository});

  final ServerRepository _serverRepository;

  @override
  Stream<List<ServerConfig>> watch() =>
      _serverRepository.watchServers().distinct(listEquals);
}
