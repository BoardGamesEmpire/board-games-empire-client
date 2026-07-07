import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show DioFactory;
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../auth/web_auth_repository_impl.dart';
import 'web_dio_factory.dart';

/// Registers the web network stack for the origin's server into [container].
///
/// Web has no MetaDB and no persisted `ServerConfig`: the browser can only
/// talk to the origin in the address bar, and [identity] is fetched from
/// that origin's well-known document at runtime — so this helper takes the
/// [ServerIdentity] directly.
///
/// The browser owns the session cookie, so there is no `TokenStorageService`
/// and no `TokenInterceptor`. The base URL comes from [originProvider],
/// which defaults to the browser's current origin ([Uri.base] has no origin
/// on the VM, which is also why tests inject a fixed one).
///
/// Lifecycle: the container owns the shared [Dio] and closes it on dispose;
/// the repository only closes its own resources.
void registerServerNetworkWeb({
  required DependencyContainer container,
  required ServerIdentity identity,
  String Function() originProvider = WebDioFactory.currentOrigin,
}) {
  const factory = WebDioFactory();
  container.registerSingleton<DioFactory>(factory);

  final dio = factory.buildForServer(baseUrl: originProvider());
  container.registerSingleton<Dio>(dio, dispose: (_) => dio.close());

  final authRepository = WebAuthRepositoryImpl(identity: identity, dio: dio);
  container.registerSingleton<AuthRepository>(
    authRepository,
    dispose: (_) => authRepository.onDispose(),
  );
}
