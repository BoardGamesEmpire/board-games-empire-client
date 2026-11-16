/// Resolves the server a deep link names to the device's registration of it
/// (#10, #82).
///
/// A link names its server by `bgeServerId` (the stable UUID from the
/// server's `/.well-known/bge-identity`), never by the device-local
/// `ServerConfig.id`, which differs between devices. This lookup maps one
/// to the other.
///
/// A deliberately narrow port: deep-link consumers need exactly one
/// question answered, not the full `ServerRepository` surface. The native
/// implementation (`ServerRepositoryKnownServerLookup` in
/// `native_platform`) consults the MetaDB server registry, the source of
/// truth for known servers. Web never implements this: single-origin, the
/// server segment is carried but ignored there.
abstract interface class KnownServerLookup {
  /// The registry's `ServerConfig.id` for [bgeServerId], or null when no
  /// server with that `bgeServerId` is registered.
  ///
  /// Answers regardless of connection state: a disconnected-but-registered
  /// server is still known.
  Future<String?> localServerIdFor(String bgeServerId);
}
