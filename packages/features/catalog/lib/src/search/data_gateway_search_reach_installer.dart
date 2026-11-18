import 'package:game_catalog/src/search/data_gateway_search_reach.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

/// Registers a session's [DataGatewaySearchReach] when a user session
/// activates (#795).
///
/// It lives in the user scope so the memory of a refusal ends with the
/// session: the next sign-in asks the DataGateways again, whoever signs in.
/// A new one is registered on every install, and the scope's disposal needs
/// nothing from it.
///
/// It resolves nothing, so it never throws or waits, and it may sit anywhere
/// in an installer list.
class DataGatewaySearchReachInstaller implements UserScopeInstaller {
  const DataGatewaySearchReachInstaller();

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    container.registerSingleton<DataGatewaySearchReach>(
      DataGatewaySearchReach(),
    );
  }
}
