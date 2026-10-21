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
/// hardware-bound keys), no key on the device can open the corresponding
/// database. For a server's database, recovery is then the last resort
/// (#428): [deleteServerKey], delete the file, open a fresh one, and rebuild
/// it from the server. What the file held that the server never received is
/// lost with it, and the app tells the user. That flow is owned by the
/// `ServerContext` open/close path; this service only stores, finds,
/// returns, and deletes keys.
///
/// A key the store could not *read* is not a lost key. Implementations
/// report that as [EncryptionKeyUnavailableError], never as a missing key,
/// so no caller replaces or deletes, on its own, a key that may still be
/// intact.
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

  /// Returns the stored key for [serverId], or `null` when none is stored.
  ///
  /// Never generates a key. A caller that finds the server's database file
  /// already on disk asks this instead of [getOrCreateServerKey]: a key
  /// generated for an existing file can only fail to open it (#428).
  Future<String?> findServerKey(String serverId);

  /// Returns the stored meta-database key, or `null` when none is stored.
  ///
  /// Never generates one; see [findServerKey].
  Future<String?> findMetaKey();

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

/// Thrown by an [EncryptionKeyService] when the key store itself fails: a
/// key could not be read, written or deleted.
///
/// It says nothing about the key. The key may still be stored, intact, and
/// the next attempt may succeed. So callers never read this as "no key",
/// and never respond to it by generating or deleting one on their own. The
/// one path that can still delete a key after it is the shell's reset of
/// the meta database, offered after repeated failed boots and run only on
/// the user's confirmation. It is not `DatabaseKeyError`, which means a key
/// was obtained and the database did not decrypt with it.
///
/// Server restore at start-up fails the whole boot on this error, which the
/// shell shows as a retryable error, and leaves the server's persisted
/// connection state alone so the next attempt restores it (#428).
class EncryptionKeyUnavailableError implements Exception {
  /// Creates the error, keeping the key store's own failure as [cause].
  const EncryptionKeyUnavailableError({this.cause});

  /// The key store's failure, typically a `PlatformException`.
  final Object? cause;

  @override
  String toString() =>
      'EncryptionKeyUnavailableError: the key store could not be reached. '
      'Stored keys are unchanged, and the operation can be retried.'
      '${cause == null ? '' : ' Cause: $cause'}';
}
