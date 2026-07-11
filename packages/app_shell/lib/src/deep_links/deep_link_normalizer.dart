import 'deep_link_redaction.dart';

/// Normalization of raw `bge://` deep-link URIs into router locations (#10).
///
/// The published pattern is `bge://server/{serverId}/{resource-path}[?...]`
/// while the declared route table (see `reservedDeepLinkPathPatterns`)
/// speaks path form: `/server/:serverId/...`. A raw URI therefore parses
/// as scheme `bge`, host `server`, and a path whose first segment is the
/// serverId — [normalizeDeepLink] validates that shape and rewrites it,
/// rejecting anything else (`bge://evil/...` must never reach the router).

/// Why a raw deep link was rejected. Reasons are safe to log; the URI
/// that produced them is not (see [redactDeepLinkForLog]).
enum DeepLinkRejectionReason {
  /// The scheme is not `bge`.
  unsupportedScheme,

  /// The authority is not the bare literal `server` (wrong host, or a
  /// userInfo/port component is present).
  unexpectedAuthority,

  /// No serverId path segment (`bge://server`, `bge://server//...`).
  missingServerId,

  /// A serverId but no resource path (`bge://server/abc`): there is
  /// nothing to route to.
  missingResourcePath,
}

/// A deep link that passed validation, expressed in the router's terms.
final class NormalizedDeepLink {
  const NormalizedDeepLink({required this.serverId, required this.location});

  /// The client-local server identifier from the link (the MetaDB-assigned
  /// id, not a hostname), percent-decoded. Validated against the server
  /// registry by [KnownServerLookup] consumers (#82); on web it is carried
  /// but ignored (single-origin — #10 decision).
  final String serverId;

  /// The `go_router` location: `/server/{serverId}/{resource-path}` plus
  /// the original query, matching a declared reserved pattern's shape.
  /// Path segments keep their original percent-encoding; the fragment, if
  /// any, is dropped during normalization.
  final String location;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NormalizedDeepLink &&
          other.serverId == serverId &&
          other.location == location;

  @override
  int get hashCode => Object.hash(serverId, location);

  /// Redacted — [location] can carry invitation/RSVP tokens, and
  /// `toString` leaks into logs, test failures, and crash breadcrumbs.
  @override
  String toString() =>
      'NormalizedDeepLink(serverId: $serverId, '
      'location: ${redactDeepLinkForLog(Uri.parse(location))})';
}

/// Outcome of [normalizeDeepLink].
sealed class DeepLinkNormalizationResult {
  const DeepLinkNormalizationResult();
}

/// The URI matched the published pattern; [link] is router-ready.
final class DeepLinkNormalized extends DeepLinkNormalizationResult {
  const DeepLinkNormalized(this.link);

  final NormalizedDeepLink link;
}

/// The URI did not match the published pattern and must be dropped.
final class DeepLinkRejected extends DeepLinkNormalizationResult {
  const DeepLinkRejected(this.reason);

  final DeepLinkRejectionReason reason;
}

/// Validates a raw incoming URI against the published `bge://` pattern and
/// rewrites it to the path form the router declares.
///
/// Contract (encoded by `deep_link_normalizer_test.dart`):
/// - scheme must be `bge` (case-insensitive: `Uri` lowercases schemes and
///   hosts during parsing, so `BGE://SERVER/...` arrives normalized);
/// - authority must be the bare literal `server` — a userInfo or explicit
///   port component is a mismatch, and any other host is rejected;
/// - the first path segment is the serverId and must be non-empty;
/// - at least one further path segment (the resource path) must follow;
/// - the query string is preserved verbatim; the fragment is dropped;
/// - percent-encoded path segments survive as single segments
///   (`a%2Fb` stays one segment, not two), which is why the rewrite works
///   on the *raw* path rather than the decoded `pathSegments`.
DeepLinkNormalizationResult normalizeDeepLink(Uri uri) {
  if (uri.scheme != 'bge') {
    return const DeepLinkRejected(DeepLinkRejectionReason.unsupportedScheme);
  }
  if (uri.host != 'server' || uri.hasPort || uri.userInfo.isNotEmpty) {
    return const DeepLinkRejected(DeepLinkRejectionReason.unexpectedAuthority);
  }

  // Raw (still-encoded) segments so an encoded slash inside a segment
  // cannot split it during the rewrite. Dart's Uri keeps structural
  // escapes like %2F encoded in `path`.
  final rawPath = uri.path;
  final trimmedPath = rawPath.startsWith('/') ? rawPath.substring(1) : rawPath;
  if (trimmedPath.isEmpty) {
    return const DeepLinkRejected(DeepLinkRejectionReason.missingServerId);
  }

  final segments = trimmedPath.split('/');
  final rawServerId = segments.first;
  if (rawServerId.isEmpty) {
    return const DeepLinkRejected(DeepLinkRejectionReason.missingServerId);
  }

  final resourceSegments = segments.sublist(1);
  if (!resourceSegments.any((segment) => segment.isNotEmpty)) {
    return const DeepLinkRejected(DeepLinkRejectionReason.missingResourcePath);
  }

  final location = StringBuffer('/server/')..writeAll(segments, '/');
  if (uri.query.isNotEmpty) {
    location
      ..write('?')
      ..write(uri.query);
  }
  // The fragment is intentionally dropped: no reserved pattern uses one.

  return DeepLinkNormalized(
    NormalizedDeepLink(
      serverId: Uri.decodeComponent(rawServerId),
      location: location.toString(),
    ),
  );
}
