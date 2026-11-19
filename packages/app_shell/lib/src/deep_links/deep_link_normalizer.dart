import 'package:app_shell/src/deep_links/deep_link_redaction.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:flutter/foundation.dart';

/// Normalization of raw `bge://` deep-link URIs into router locations (#10).
///
/// The published pattern is `bge://server/{serverId}/{resource-path}[?...]`
/// while the declared route table (see `reservedDeepLinkPathPatterns`)
/// speaks path form: `/server/:serverId/...`. A raw URI therefore parses
/// as scheme `bge`, host `server`, and a path whose first segment is the
/// serverId — [normalizeDeepLink] validates that shape and rewrites it.
/// The app's own declared locations (`appDeepLinkLocations`, #126) are the
/// other accepted shape: `bge://settings` parses as host `settings`.
/// Anything else is rejected (`bge://evil/...` must never reach the
/// router).

/// Why a raw deep link was rejected. Reasons are safe to log; the URI
/// that produced them is not (see [redactDeepLinkForLog]).
enum DeepLinkRejectionReason {
  /// The scheme is not `bge`.
  unsupportedScheme,

  /// The authority is not the bare literal `server` or an app host (wrong
  /// host, or a userInfo/port component is present).
  unexpectedAuthority,

  /// The host is an app host (`bge://settings`) but the path is not a
  /// declared app location (`bge://settings/bogus`, #126).
  undeclaredAppLocation,

  /// No serverId path segment (`bge://server`, `bge://server//...`).
  missingServerId,

  /// A serverId but no resource path (`bge://server/abc`): there is
  /// nothing to route to.
  missingResourcePath,

  /// The serverId carries a percent-escape that is not valid UTF-8
  /// (`bge://server/%FF/...`), so it cannot be decoded.
  malformedServerId,
}

/// A deep link that passed validation, expressed in the router's terms.
///
/// Either names a server ([ServerDeepLink]) or is the app's own, with no
/// server to resolve ([AppDeepLink], #126).
@immutable
sealed class NormalizedDeepLink {
  const NormalizedDeepLink();

  /// The `go_router` location the link opens.
  String get location;
}

/// A link into one server's resources (`bge://server/{id}/...`).
@immutable
final class ServerDeepLink extends NormalizedDeepLink {
  const ServerDeepLink({required this.serverId, required this.location});

  /// The server's `bgeServerId` from the link (the stable UUID from
  /// `/.well-known/bge-identity`, not a hostname or the device-local
  /// `ServerConfig.id`), percent-decoded. Resolved against the server
  /// registry by `KnownServerLookup` consumers (#82).
  final String serverId;

  /// The `go_router` location: `/server/{serverId}/{resource-path}` plus
  /// the original query, matching a declared reserved pattern's shape.
  /// Path segments keep their original percent-encoding; the fragment, if
  /// any, is dropped during normalization.
  @override
  final String location;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerDeepLink &&
          other.serverId == serverId &&
          other.location == location;

  @override
  int get hashCode => Object.hash(serverId, location);

  /// Redacted — [location] can carry invitation/RSVP tokens and [serverId]
  /// the userInfo shape it was lifted out of, and `toString` leaks into
  /// logs, test failures, and crash breadcrumbs.
  ///
  /// [serverId] is stored decoded, so it is re-encoded before the redactor
  /// (whose contract is raw segments) — otherwise a control character
  /// smuggled in as an escape (`%0Aforged`) would arrive here as a real
  /// newline and let a link forge a second log line.
  @override
  String toString() =>
      'ServerDeepLink(serverId: '
      '${redactDeepLinkSegmentForLog(Uri.encodeComponent(serverId))}, '
      'location: ${redactDeepLinkForLog(Uri.parse(location))})';
}

/// A link to a place in the app itself, naming no server, so it needs no
/// server lookup or switch (#126). A web cold load is one (#83).
@immutable
final class AppDeepLink extends NormalizedDeepLink {
  const AppDeepLink({required this.location});

  @override
  final String location;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppDeepLink && other.location == location;

  @override
  int get hashCode => location.hashCode;

  /// Redacted like [ServerDeepLink.toString]: the location can carry a
  /// token or a query value.
  @override
  String toString() =>
      'AppDeepLink(location: ${redactDeepLinkForLog(Uri.parse(location))})';
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
/// - authority must be the bare literal `server` or an app host (the first
///   segment of an `appDeepLinkLocations` entry) — a userInfo or explicit
///   port component is a mismatch, and any other host is rejected;
/// - an app host opens only a declared app location (the raw path, one
///   trailing `/` allowed, matched exactly and case-sensitively), as an
///   [AppDeepLink] with the query kept and the fragment dropped (#126);
/// - for a `server` link:
///   - the first path segment is the serverId and must be non-empty, and
///     must decode — an escape that is not valid UTF-8 is a rejection,
///     since a malformed link may never leave by way of an exception;
///   - at least one further path segment (the resource path) must follow;
/// - the query string is preserved verbatim; the fragment is dropped;
/// - percent-encoded path segments survive as single segments
///   (`a%2Fb` stays one segment, not two), which is why the rewrite works
///   on the *raw* path rather than the decoded `pathSegments`.
DeepLinkNormalizationResult normalizeDeepLink(Uri uri) {
  if (uri.scheme != 'bge') {
    return const DeepLinkRejected(DeepLinkRejectionReason.unsupportedScheme);
  }
  final host = uri.host;
  if (uri.hasPort || uri.userInfo.isNotEmpty) {
    return const DeepLinkRejected(DeepLinkRejectionReason.unexpectedAuthority);
  }
  if (host != 'server') {
    return _normalizeAppLink(uri);
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

  // Decoded here rather than at the return, so a hostile escape leaves as
  // a rejection like every other malformed link. `Uri.decodeComponent`
  // throws on an escape that is not valid UTF-8, and this is the last step
  // of the pipeline — the throw would escape `DeepLinkHandler._onUri` past
  // both of its log calls, and `Stream.listen`'s `onError` does not catch
  // a throw out of `onData`, so the link vanished without a breadcrumb.
  final String serverId;
  try {
    serverId = Uri.decodeComponent(rawServerId);
  } on FormatException {
    return const DeepLinkRejected(DeepLinkRejectionReason.malformedServerId);
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
    ServerDeepLink(serverId: serverId, location: location.toString()),
  );
}

/// The host of each declared app location (`bge://settings` has host
/// `settings`), derived once (#126).
final Set<String> _appDeepLinkHosts = {
  for (final location in appDeepLinkLocations) location.split('/')[1],
};

/// The app-host branch of [normalizeDeepLink] (#126).
DeepLinkNormalizationResult _normalizeAppLink(Uri uri) {
  final host = uri.host;
  if (!_appDeepLinkHosts.contains(host)) {
    return const DeepLinkRejected(DeepLinkRejectionReason.unexpectedAuthority);
  }

  // The raw path, so an encoded slash stays encoded and cannot match.
  final rawPath = uri.path;
  final path = rawPath.endsWith('/')
      ? rawPath.substring(0, rawPath.length - 1)
      : rawPath;
  final location = '/$host$path';
  if (!appDeepLinkLocations.contains(location)) {
    return const DeepLinkRejected(
      DeepLinkRejectionReason.undeclaredAppLocation,
    );
  }

  return DeepLinkNormalized(
    AppDeepLink(
      location: uri.query.isEmpty ? location : '$location?${uri.query}',
    ),
  );
}
