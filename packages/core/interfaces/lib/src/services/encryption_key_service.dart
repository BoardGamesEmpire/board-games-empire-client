/// Manages the encryption keys protecting BGE's on-device databases.
///
/// One key exists per connected server (keyed by `serverId`) plus a single
/// device-global key for the meta database. Keys are opaque to callers: the
/// only contract is the format below and that the same identifier always
/// yields the same key until it is deleted.
///
/// ## Key format
///
/// Every key is a **64-character lowercase hexadecimal string** (256 bits of
/// cryptographically secure randomness). Implementations must generate keys
/// from a cryptographically secure source and must persist a newly generated
/// key *before* returning it, so a crash between generation and first use
/// cannot strand an encrypted database without its key.
///
/// ## Key loss and recovery
///
/// The OS keychain backing an implementation is the security boundary. If a
/// key is lost (keychain reset, device migration that cannot carry
/// hardware-bound keys), the corresponding database is unrecoverable by
/// design: the recovery path is delete-the-file, [deleteServerKey] (or
/// [deleteMetaKey]), regenerate via the get-or-create call, and re-sync from
/// the server — the client database is a cache, the server is the source of
/// truth. That flow is owned by the `ServerContext` open/close path; this
/// service only stores, returns, and deletes keys.
abstract interface class EncryptionKeyService {
  /// Returns the encryption key for the server identified by [serverId],
  /// generating and persisting a new one if none exists yet.
  ///
  /// Idempotent: repeated calls with the same [serverId] return the same key
  /// until [deleteServerKey] is called for it.
  Future<String> getOrCreateServerKey(String serverId);

  /// Returns the device-global encryption key for the meta database,
  /// generating and persisting a new one if none exists yet.
  ///
  /// Idempotent: repeated calls return the same key until [deleteMetaKey]
  /// is called.
  Future<String> getOrCreateMetaKey();

  /// Deletes the stored key for [serverId], if any.
  ///
  /// After this call the next [getOrCreateServerKey] for the same server
  /// generates a fresh key. Deleting the key of a live encrypted database
  /// makes that database permanently unreadable — callers are expected to
  /// delete the database file in the same recovery flow.
  Future<void> deleteServerKey(String serverId);

  /// Deletes the stored meta-database key, if any.
  ///
  /// Same contract as [deleteServerKey]: the next [getOrCreateMetaKey]
  /// generates a fresh key, and the old meta database file must be deleted
  /// alongside.
  Future<void> deleteMetaKey();
}
