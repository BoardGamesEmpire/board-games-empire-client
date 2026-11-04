import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import 'well_known_client.dart';

/// The root-scope collaborators adding a server needs, registered and
/// resolved as one unit (#216).
///
/// Server-add runs before any `ServerContext` exists, so all four come from
/// the root container. Resolving them together means a composition that
/// leaves one out fails in one place, with the absent member named there,
/// instead of a route discovering it member by member. Bootstrap resolves
/// it before pinning the app to server-add (#218), and the shell resolves
/// it once more when it builds the route.
///
/// It lives here rather than in `interfaces` because [WellKnownClient] is
/// declared in this package, which already depends on `interfaces`.
final class ServerOnboardingDeps {
  const ServerOnboardingDeps({
    required this.wellKnownClient,
    required this.versionNegotiator,
    required this.connectivityService,
    required this.buildInfo,
  });

  /// Resolves each member from [container] with `get`.
  ///
  /// Throws if any member is not registered or its factory throws. The
  /// container's error names the member that failed.
  factory ServerOnboardingDeps.from(DependencyContainer container) =>
      ServerOnboardingDeps(
        wellKnownClient: container.get<WellKnownClient>(),
        versionNegotiator: container.get<VersionNegotiator>(),
        connectivityService: container.get<ConnectivityService>(),
        buildInfo: container.get<BuildInfo>(),
      );

  /// Fetches the server's discovery document.
  final WellKnownClient wellKnownClient;

  /// Checks this build against the versions the server accepts.
  final VersionNegotiator versionNegotiator;

  /// Lets the flow tell an offline device from an unreachable server.
  final ConnectivityService connectivityService;

  /// This build's version, for the negotiation.
  final BuildInfo buildInfo;
}
