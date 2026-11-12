/// Durable record that a server's stored session must not be restored (#356).
///
/// The in-memory latch `TokenStorageService.clear()` sets does not outlive the
/// process, so a keychain delete that failed leaves a well-formed payload that
/// the next cold start reads back. This is the record that survives the
/// restart: written before the delete, read before the payload is returned.
///
/// Not the glossary's sync Tombstone (GLOSSARY.md): that is a deleted record
/// the app retains; this is a marker a new sign-in removes.
///
/// ## Keyed by the server's own id
///
/// Every method takes the `bgeServerId` the server vends, the same id the
/// keychain key uses, and not the registry's local `id`.
///
/// ## What it is not
///
/// It holds no token and no user data, only whether a session was disowned. A
/// server that is no longer registered has no marker to read, so a removed
/// server reads as not revoked.
///
/// Removing a row leaves the keychain alone. Today the rollback of a failed
/// onboarding removes one, and a device-local reset removes them all and
/// deletes the payloads itself. A user-facing way to remove a server has to
/// delete the payload as well, or adding that server again reads a session its
/// marker had refused.
abstract class SessionTombstoneStore {
  /// Whether [bgeServerId]'s stored session has been marked as not to be
  /// restored. A server with no row reads as not revoked.
  Future<bool> isRevoked(String bgeServerId);

  /// Throws `ServerNotFoundException` when no row matches: the marker was
  /// not written, and an UPDATE matching nothing does not throw by itself.
  Future<void> markRevoked(String bgeServerId);

  /// A missing row is not an error: there is nothing to clear.
  Future<void> clearRevoked(String bgeServerId);
}
