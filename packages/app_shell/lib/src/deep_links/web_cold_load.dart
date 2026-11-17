import 'package:app_shell/src/deep_links/deep_link_normalizer.dart';
import 'package:app_shell/src/router/app_router.dart';

/// The `serverId` a web cold load's link carries (#83).
///
/// Web is single-server and same-origin, so the consumer ignores the
/// server a web link names; the slot keeps one type all the same. Server
/// ids are UUIDs, so this can never name a registered server. It is logged
/// through the same redaction as any server id.
const webColdLoadServerId = 'web-cold-load';

/// The link that holds a web cold load's [location] through bootstrap and
/// sign-in, so that it opens once the app is ready (#83).
///
/// Null for the locations the app opens on anyway: home, and the bootstrap
/// screens, splash included. The query is kept and the fragment dropped,
/// as the normalizer does for a native link.
NormalizedDeepLink? coldLoadLinkFor(Uri location) {
  final path = location.path;
  if (path == AppRoutes.home || AppRoutes.bootstrapLocations.contains(path)) {
    return null;
  }
  return NormalizedDeepLink(
    serverId: webColdLoadServerId,
    location: location.hasQuery ? '$path?${location.query}' : path,
  );
}
