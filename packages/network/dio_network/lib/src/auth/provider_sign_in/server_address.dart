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
