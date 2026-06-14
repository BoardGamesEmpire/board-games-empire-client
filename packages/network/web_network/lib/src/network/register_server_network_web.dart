import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show DioFactory;
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../auth/web_auth_repository_impl.dart';
import 'web_dio_factory.dart';

/// Registers the web network stack for [config] into the per-server
/// [container].
///
/// The browser owns the session cookie, so there is no `TokenStorageService`
/// and no `TokenInterceptor`. The base URL comes from the browser's current
/// origin (the address bar) rather than [ServerConfig.serverUrl] — on web the
/// app is served from the same origin it talks to.
///
/// Lifecycle: the container owns the shared [Dio] and closes it on dispose; the
/// repository only closes its own resources.
void registerServerNetworkWeb({
  required DependencyContainer container,
  required ServerConfig config,
}) {
  const factory = WebDioFactory();
  container.registerSingleton<DioFactory>(factory);

  final dio = factory.buildForServer(baseUrl: WebDioFactory.currentOrigin());
  container.registerSingleton<Dio>(dio, dispose: (_) => dio.close());

  final authRepository = WebAuthRepositoryImpl(
    identity: config.cachedIdentity,
    dio: dio,
  );
  container.registerSingleton<AuthRepository>(
    authRepository,
    dispose: (_) => authRepository.onDispose(),
  );
}
