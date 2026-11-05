import '../../network/dio_factory.dart';

/// Whether [a] and [b] name the same server (#583).
///
/// Compares the lowercase scheme and host, the effective port (443 for https
/// and 80 for http when absent) and the path without one trailing `/`, so
/// `''` equals `/`. The path is case-sensitive. Query, fragment and userinfo
/// are ignored. An address that does not parse, or has no scheme or no host,
/// is never the same as anything, itself included.
bool isSameServerAddress(String a, String b) {
  final left = _normalise(a);
  final right = _normalise(b);

  return left != null && right != null && left == right;
}

String? _normalise(String address) {
  final uri = Uri.tryParse(address);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;

  final path = uri.path.endsWith('/')
      ? uri.path.substring(0, uri.path.length - 1)
      : uri.path;

  return '${uri.scheme}://${uri.host}:${uri.port}$path';
}

/// The address of the discovery path [endpoint] on the server added as
/// [serverUrl] (#583).
///
/// Composed the way the per-server `Dio` composes every other discovery path:
/// [serverUrl] without one trailing `/`, then [endpoint]. An [endpoint] that is
/// already an `http:` or `https:` address is kept as it is, but only on the
/// server's own origin: the same scheme, host and effective port.
///
/// The token route is posted the one-time code and the PKCE verifier, which
/// together are a session. An absolute route on another host, or in cleartext
/// under an `https` server, would hand them to an address that passed neither
/// the issuer check nor the return's `iss` check. The start route is held to
/// the same origin, since the tab it opens is where the code is issued.
///
/// Not `Uri.parse(serverUrl).resolve(endpoint)`. That drops a server reached
/// under a path prefix to its origin (`https://example.com/bge` plus
/// `/api/auth/x` gives `https://example.com/api/auth/x`), while email sign-in
/// and the session check keep the prefix.
///
/// Null when the result is not an `http` or `https` address with a host, such
/// as a malformed discovery path, and when an absolute [endpoint] is on
/// another origin. Callers refuse that with a modelled exception rather than
/// let a `FormatException` leave an auth method (#181).
Uri? resolveServerEndpoint(String serverUrl, String endpoint) {
  final absolute = endpoint.startsWith(_absoluteHttp);
  final address = absolute
      ? endpoint
      : DefaultDioFactory.normalizeBaseUrl(serverUrl) + endpoint;

  final uri = Uri.tryParse(address);
  if (uri == null || uri.host.isEmpty) return null;
  if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
  if (absolute && !_isSameOrigin(uri, Uri.tryParse(serverUrl))) return null;

  return uri;
}

/// Whether [a] and [b] share a scheme, a host and an effective port. Scheme
/// and host compare without case, as `Uri` already lowercases them.
bool _isSameOrigin(Uri a, Uri? b) =>
    b != null &&
    b.host.isNotEmpty &&
    a.scheme == b.scheme &&
    a.host == b.host &&
    a.port == b.port;

/// The test `Dio` itself uses for a path that ignores the base URL.
final RegExp _absoluteHttp = RegExp('https?:');
