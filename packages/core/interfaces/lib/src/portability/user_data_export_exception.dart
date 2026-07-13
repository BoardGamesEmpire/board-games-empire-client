/// Typed failures raised while assembling a user-data export bundle
/// (#11).
///
/// Sealed so the export-confirmation UI (#93) can switch exhaustively
/// and localize each failure. The bundler is responsible for mapping
/// every foreseeable lower-layer failure (auth, server-config lookup)
/// into this hierarchy — an untyped exception escaping here would break
/// the UI's exhaustive handling.
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
/// The per-server `AuthRepository.getCachedSession` is a local read on
/// native but delegates to the network on web (httpOnly cookies are
/// opaque). Offline on web it raises an `AuthException`; the bundler
/// wraps that here rather than letting it escape the sealed hierarchy.
/// [cause] is the originating `AuthException`.
final class ExportSessionUnavailableException extends UserDataExportException {
  const ExportSessionUnavailableException({
    required Object super.cause,
    super.message =
        'Your session could not be verified. Check your connection and '
        'try again.',
  });
}

/// The server for the `ServerContext.serverId` being exported could not
/// be resolved, so the bundle's `serverId` / `serverName` metadata
/// cannot be sourced.
///
/// Covers two cases the export flow treats identically — both are a
/// dead end for producing this server's bundle:
/// - no `ServerConfig` row exists for the id, or
/// - the row exists but its cached identity is unreadable
///   (`CorruptedServerIdentityException`), whose recovery is removing
///   and re-adding the server.
///
/// [cause] carries the distinction (non-null for the corrupted-identity
/// case) for callers that need it.
final class ExportUnknownServerException extends UserDataExportException {
  ExportUnknownServerException({required this.serverId, super.cause})
    : super(
        message:
            'No server configuration could be resolved for id "$serverId". '
            'It may be missing, or its stored identity may be unreadable.',
      );

  /// The local server id (`ServerConfig.id`) that failed to resolve.
  final String serverId;
}
