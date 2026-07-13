/// Normalization and validation for the user-entered server URL (#36).
///
/// Policy (locked in the #36 design review):
/// - input is trimmed; `https://` is prepended when no scheme is given;
/// - the host must be non-empty;
/// - `http` is permitted only for loopback (`localhost`, `127.0.0.0/8`,
///   `::1`) and RFC 1918 private hosts (`10/8`, `172.16/12`,
///   `192.168/16`) — the self-hosting / LAN development reality — and
///   rejected everywhere else;
/// - any scheme other than `http`/`https` is rejected;
/// - path prefixes are preserved (a BGE server may live under a path on
///   a shared reverse proxy) and a single trailing slash is dropped
///   (matching `WellKnownClient`'s own normalization).
///
/// Pure and synchronous so the rules are unit-testable without a bloc.
sealed class ServerUrlResult {
  const ServerUrlResult();
}

/// The input normalized to a usable base URL.
final class ServerUrlValid extends ServerUrlResult {
  const ServerUrlValid(this.normalized);

  /// Scheme + host (+ port) (+ path prefix), no trailing slash.
  final String normalized;

  @override
  bool operator ==(Object other) =>
      other is ServerUrlValid && other.normalized == normalized;

  @override
  int get hashCode => normalized.hashCode;

  @override
  String toString() => 'ServerUrlValid($normalized)';
}

/// Why an input was rejected. Widget layer maps each to a localized
/// message.
enum ServerUrlError {
  /// Blank, whitespace-only, or structurally unparseable input.
  malformed,

  /// A scheme other than http/https (ftp, bge, file, …).
  unsupportedScheme,

  /// Plain http toward a host that is neither loopback nor RFC 1918.
  insecureHttp,
}

final class ServerUrlInvalid extends ServerUrlResult {
  const ServerUrlInvalid(this.error);

  final ServerUrlError error;

  @override
  bool operator ==(Object other) =>
      other is ServerUrlInvalid && other.error == error;

  @override
  int get hashCode => error.hashCode;

  @override
  String toString() => 'ServerUrlInvalid($error)';
}

/// Applies the policy above to raw user [input].
ServerUrlResult normalizeServerUrl(String input) {
  var candidate = input.trim();
  if (candidate.isEmpty) {
    return const ServerUrlInvalid(ServerUrlError.malformed);
  }

  // Prepend https:// only when no scheme is present at all. A lone
  // "scheme-relative" (//host) or partial scheme still parses; the
  // scheme check below handles the rest.
  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(candidate);
  if (!hasScheme) candidate = 'https://$candidate';

  final Uri uri;
  try {
    uri = Uri.parse(candidate);
  } on FormatException {
    return const ServerUrlInvalid(ServerUrlError.malformed);
  }

  if (uri.host.isEmpty) {
    return const ServerUrlInvalid(ServerUrlError.malformed);
  }

  // Uri.parse is lenient: "https://ht tp://x" parses with host "ht%20tp"
  // rather than throwing. A real host is a registered name
  // (letters/digits/./-, plus _ in practice) or a bracketed IPv6
  // literal — anything else (percent-escapes, spaces, slashes) means the
  // input was malformed, so reject on host shape.
  if (!_isWellFormedHost(uri.host)) {
    return const ServerUrlInvalid(ServerUrlError.malformed);
  }

  switch (uri.scheme) {
    case 'https':
      break;
    case 'http':
      if (!_isLoopbackOrPrivateHost(uri.host)) {
        return const ServerUrlInvalid(ServerUrlError.insecureHttp);
      }
      break;
    default:
      return const ServerUrlInvalid(ServerUrlError.unsupportedScheme);
  }

  // Preserve the path prefix; drop query/fragment (never part of a base
  // URL) and a trailing slash (WellKnownClient normalizes it anyway —
  // doing it here keeps the persisted ServerConfig.serverUrl canonical).
  // Note: Uri.replace(query: null) means "keep existing" in Dart, so the
  // base is reconstructed explicitly from its kept components.
  var path = uri.path;
  if (path.endsWith('/')) path = path.substring(0, path.length - 1);

  final normalized = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  ).toString();

  return ServerUrlValid(normalized);
}

bool _isWellFormedHost(String host) {
  // IPv6 literal. Uri.host may return it bracketed ("[::1]") or bare
  // ("::1") depending on the input and SDK; accept either. The presence
  // of a colon unambiguously marks IPv6 here (ports were already split
  // off by Uri parsing).
  if (host.contains(':')) {
    final inner = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    return RegExp(r'^[0-9a-fA-F:]+$').hasMatch(inner);
  }
  // Registered name / IPv4: letters, digits, dot, hyphen, underscore.
  // No spaces, no percent-escapes, no slashes — those signal a
  // malformed input that Uri.parse tolerated.
  return RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(host);
}

bool _isLoopbackOrPrivateHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' || lower == '::1' || lower == '[::1]') return true;

  final parts = lower.split('.');
  if (parts.length == 4) {
    final octets = parts.map(int.tryParse).toList();
    if (octets.every((o) => o != null && o >= 0 && o <= 255)) {
      final a = octets[0]!;
      final b = octets[1]!;
      if (a == 127) return true; // loopback
      if (a == 10) return true; // 10/8
      if (a == 172 && b >= 16 && b <= 31) return true; // 172.16/12
      if (a == 192 && b == 168) return true; // 192.168/16
    }
  }
  return false;
}
