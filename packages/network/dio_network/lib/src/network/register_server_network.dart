import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../auth/auth_repository_impl.dart';
import '../auth/token_storage_service.dart';
import 'dev_log_interceptor.dart';
import 'dio_factory.dart';
import 'token_interceptor.dart';

/// Registers the mobile/desktop network stack for [config] into the per-server
/// [container].
///
/// This is the composition root for the Dio-based stack — the one place that
/// knows how the pieces fit together. It wires:
///
///   TokenStorageService -> TokenInterceptor -> DioFactory -> shared Dio
///                                                          -> AuthRepository
///
/// The factory's [Dio] is registered as a shared per-server singleton so future
/// repositories (game search, collection sync, …) resolve the same instance and
/// inherit the interceptor stack — including token attachment — without any
/// construction-order dependency.
///
/// Lifecycle: the container owns the shared [Dio] and closes it on dispose; the
/// repository only closes its own resources (it must not close a [Dio] that
/// other repositories share).
void registerServerNetwork({
  required DependencyContainer container,
  required ServerConfig config,
}) {
  // Token storage is keyed by the stable server-vended UUID so it survives
  // user-facing URL changes for the same server instance.
  final tokenStorage = TokenStorageService(serverId: config.bgeServerId);
  container.registerSingleton<TokenStorageService>(tokenStorage);

  const factory = DefaultDioFactory();
  container.registerSingleton<DioFactory>(factory);

  final dio = factory.buildForServer(
    baseUrl: config.serverUrl,
    interceptors: [
      // TEMP (#101, removed by #100): first in the stack so it observes
      // every outgoing request and its resolution. Redaction-safe — logs
      // method + resolved URI + status/error type only. Gated to non-release
      // (debug/profile) builds: even redacted, a per-request diagnostic adds
      // noise and residual risk in a product build, and it only earns its
      // keep while the pre-wire connection issue is being chased (PR #103
      // review).
      if (!kReleaseMode) DevLogInterceptor(),
      TokenInterceptor(tokenStorage: tokenStorage),
    ],
  );
  container.registerSingleton<Dio>(dio, dispose: (_) => dio.close());

  final authRepository = AuthRepositoryImpl(
    identity: config.cachedIdentity,
    tokenStorage: tokenStorage,
    dio: dio,
  );
  container.registerSingleton<AuthRepository>(
    authRepository,
    dispose: (_) => authRepository.onDispose(),
  );
}
