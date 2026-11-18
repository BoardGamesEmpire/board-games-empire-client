import 'package:models/domain.dart';

/// The servers this device has registered, as a stream the server manager
/// reads (#134).
///
/// A deliberately narrow port: the manager needs the list and its changes,
/// not the full `ServerRepository` surface. The native implementation
/// (`ServerRepositoryRegisteredServers` in `native_platform`) reads the
/// MetaDB server registry, the source of truth for known servers. Web never
/// implements this: single-origin, there is no registry to list.
abstract interface class RegisteredServers {
  /// Every registered server, emitting again whenever the registry changes.
  ///
  /// Lists regardless of connection state: a disconnected-but-registered
  /// server is still registered, and is the one the user most needs to see.
  Stream<List<ServerConfig>> watch();
}
