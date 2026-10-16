import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'data_gateway_access.dart';

/// Registers the session's [DataGatewayAccess] and starts its first check
/// when a user session activates (#41).
///
/// Per user, not per server, because the answer is the user's role: a
/// sign-out pops this scope, and the next user on the same server is asked
/// afresh.
///
/// Shared by both composition roots, like `HouseholdHydrateInstaller`, and
/// for the same reason: it needs only `interfaces` and `network_interface`.
/// The [DataGatewayRemoteDataSource] it resolves is registered per server by
/// the network installer and reached because the user-scope container view
/// falls through to the per-server scope.
///
/// ## Nothing here may throw or wait
///
/// A throw from [install] aborts the session's activation, and the shell
/// converges that to a sign-out. So the check runs unawaited, and a container
/// with no DataGateway client registers nothing, which every reader treats as
/// "no admin entry".
///
/// ## Asking again
///
/// A check that failed for a reason other than a 403 leaves the answer
/// unknown. It is registered with the session's [SessionRehydrator] so the
/// next connectivity edge or app resume asks again; once the answer is
/// settled, it is not asked again. A composition without the rehydrator
/// skips that, and the screen's own read still keeps the answer current.
class DataGatewayAccessInstaller implements UserScopeInstaller {
  const DataGatewayAccessInstaller();

  static final BgeLogger _log = BgeLogger('bge.data_gateway.access.install');

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (!container.isRegistered<DataGatewayRemoteDataSource>()) {
      _log.debug(
        'No DataGateway client on this server; skipping the access check',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final access = DataGatewayAccess(
      remote: container.get<DataGatewayRemoteDataSource>(),
    );
    container.registerSingleton<DataGatewayAccess>(
      access,
      dispose: (a) => a.dispose(),
    );

    if (container.isRegistered<SessionRehydrator>()) {
      container.get<SessionRehydrator>().register(
        'data_gateway_access',
        isStale: () =>
            access.value.read == DataGatewayRead.unknown && !access.isChecking,
        run: access.check,
      );
    }

    unawaited(access.check());
  }
}
