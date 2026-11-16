/// Typed failures raised while assembling a user-data export bundle
/// (#11).
///
/// Sealed so the export-confirmation UI (#93) can switch exhaustively
/// and localize each failure. The bundler is responsible for mapping
/// every foreseeable lower-layer failure (the session read) into this
/// hierarchy — an untyped exception escaping here would break the UI's
/// exhaustive handling.
sealed class UserDataExportException implements Exception {
  const UserDataExportException({required this.message, this.cause});

  /// Developer-facing description. UI copy is localized separately.
  final String message;

  /// The underlying failure this wraps, when one exists. Preserved so
  /// callers and logs can inspect the root cause; the original stack
  /// trace is retained at the throw site via
  /// [Error.throwWithStackTrace].
  final Object? cause;

  @override
  // The subclass name is the intended text, and a literal per subclass
  // would change it.
  // ignore: no_runtimetype_tostring
  String toString() => '$runtimeType: $message';
}

/// Export requires an authenticated session and there is definitively
/// none — the session read succeeded and returned "unauthenticated".
///
/// Distinct from [ExportSessionUnavailableException]: this is a settled
/// negative answer, not a failure to obtain one. Never degrade to a
/// silent empty bundle.
final class ExportNotAuthenticatedException extends UserDataExportException {
  const ExportNotAuthenticatedException({
    super.message = 'An authenticated session is required to export user data.',
  });
}

/// The session state could not be determined, so export cannot safely
/// proceed.
///
/// The per-server `AuthRepository.getCachedSession` raised an
/// `AuthException` (for example an unreadable secure store); the
/// bundler wraps it here rather than letting it escape the sealed
/// hierarchy. [cause] is the originating `AuthException`.
final class ExportSessionUnavailableException extends UserDataExportException {
  const ExportSessionUnavailableException({
    required Object super.cause,
    super.message = 'The cached session could not be read on this device.',
  });
}
