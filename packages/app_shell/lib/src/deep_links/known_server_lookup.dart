/// Answers whether a deep link's serverId names a server this device
/// knows (#10).
///
/// A deliberately narrow port: deep-link consumers need exactly one
/// question answered, not the full `ServerRepository` surface. The native
/// implementation (`ServerRepositoryKnownServerLookup` in
/// `native_platform`) consults the MetaDB server registry — the source of
/// truth for known servers (#10 decision). Web never implements this:
/// single-origin, the serverId segment is carried but ignored there.
///
/// #10 delivers the contract and the native implementation; wiring a
/// lookup into the live link flow is #82's consumption scope (unknown →
/// "add server" affordance, known-but-inactive → switch).
abstract interface class KnownServerLookup {
  /// True when [serverId] is registered in the device's server registry,
  /// regardless of its connection state — a disconnected-but-registered
  /// server is still *known*.
  Future<bool> isKnownServer(String serverId);
}
