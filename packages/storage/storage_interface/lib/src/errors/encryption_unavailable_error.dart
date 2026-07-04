/// Thrown when encryption is required but the bundled SQLite build does not
/// provide it — i.e. `PRAGMA cipher` reports no cipher support.
///
/// Unlike [DatabaseKeyError] this is **not** a recoverable runtime
/// condition: it means the application was built without the
/// SQLite3MultipleCiphers user-define (`hooks: user_defines: sqlite3:
/// source: sqlite3mc` in the workspace-root `pubspec.yaml`) or the build
/// hook was otherwise misconfigured. It indicates a broken build, and the
/// correct response is to fail fast and loudly rather than silently fall
/// back to writing plaintext.
///
/// Kept in `storage_interface` alongside the other storage contract types so
/// bootstrap code can distinguish "this build is wrong" from "this database
/// needs recovery" without depending on a concrete backend.
class EncryptionUnavailableError extends Error {
  /// Creates the error. [detail] may add build-specific context.
  EncryptionUnavailableError([this.detail]);

  /// Optional extra context (e.g. which database open triggered the check).
  final String? detail;

  @override
  String toString() =>
      'EncryptionUnavailableError: the bundled SQLite build has no cipher '
      'support. The workspace root pubspec.yaml must select an encrypted '
      "build via `hooks: user_defines: sqlite3: source: sqlite3mc`."
      '${detail == null ? '' : ' ($detail)'}';
}
