import 'package:models/domain.dart';

/// Abstract client for fetching the BGE server discovery document.
///
/// The /.well-known/bge-identity endpoint is unauthenticated and must be
/// reachable before any credentials exist. Implementations must not attach
/// auth tokens or session cookies to these requests.
///
/// Typical usage during server onboarding:
/// ```dart
/// final identity = await wellKnownClient.fetchIdentity('https://my-bge.example.com');
/// // identity.serverId uniquely identifies the server across URL changes
/// // identity.strategies drives the login UI
/// ```
abstract class WellKnownClient {
  /// Fetches and parses the BGE server identity document from
  /// `$serverUrl/.well-known/bge-identity`.
  ///
  /// [serverUrl] is the base URL of the BGE server (e.g. `https://api.example.com`).
  /// Trailing slashes are normalized.
  ///
  /// Throws:
  /// - [WellKnownUnreachableException] — network failure or timeout
  /// - [WellKnownNotFoundException] — server returned 404 (not a BGE server)
  /// - [WellKnownInvalidResponseException] — non-200 status or unparseable body
  Future<ServerIdentity> fetchIdentity(String serverUrl);
}

/// Base class for all well-known fetch failures.
sealed class WellKnownException implements Exception {
  const WellKnownException({
    required this.serverUrl,
    required this.message,
    this.cause,
  });

  final String serverUrl;
  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType(serverUrl: $serverUrl, message: $message)';
}

/// The server could not be reached due to a network failure or timeout.
/// The user should verify the URL and their connection.
final class WellKnownUnreachableException extends WellKnownException {
  const WellKnownUnreachableException({
    required super.serverUrl,
    required super.message,
    super.cause,
  });
}

/// The server responded with 404. Either the URL is wrong or this is not
/// a BGE server instance.
final class WellKnownNotFoundException extends WellKnownException {
  const WellKnownNotFoundException({
    required super.serverUrl,
    required super.message,
  });
}

/// The server responded but the body could not be parsed as a valid
/// [ServerIdentity]. May indicate a version mismatch between client and server.
final class WellKnownInvalidResponseException extends WellKnownException {
  const WellKnownInvalidResponseException({
    required super.serverUrl,
    required super.message,
    super.cause,
    this.statusCode,
  });

  /// HTTP status code if the failure was a non-200 response, null for parse
  /// errors on a 200 response.
  final int? statusCode;
}
