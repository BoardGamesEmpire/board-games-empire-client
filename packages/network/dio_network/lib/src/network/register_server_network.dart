import 'package:di/di.dart' show ServerSkewClockService;
import 'package:dio/dio.dart';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart' show ClockService;
import 'package:models/domain.dart';
import 'package:observability/observability.dart' show FeedbackTransport;

import '../auth/auth_repository_impl.dart';
import '../auth/token_storage_service.dart';
import '../feedback/feedback_dio_transport.dart';
import 'clock_skew_interceptor.dart';
import 'dio_factory.dart';
import 'network_log_interceptor.dart';
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

  // #12: per-server skew-corrected clock. Registered here — not in its
  // own installer — per the registration convention: it is fed by this
  // stack's Dio responses (via ClockSkewInterceptor below). Registered
  // under the read interface only; the feed surface (ClockSkewRecorder)
  // is a private wiring detail between this composition root and the
  // interceptor. Each server has its own clock, so estimates never leak
  // across scopes.
  final clock = ServerSkewClockService();
  container.registerSingleton<ClockService>(
    clock,
    dispose: (_) => clock.dispose(),
  );

  final dio = factory.buildForServer(
    baseUrl: config.serverUrl,
    interceptors: [
      // #100: permanent network observability, first in the stack so it
      // observes every outgoing request and its resolution. Redaction-safe
      // — logs method + resolved URI + status/error type only, never
      // bodies, headers, query parameters, or tokens. Request/response
      // tracing is at debug and self-gates to non-release builds; a
      // transport failure logs at error always.
      NetworkLogInterceptor(),
      TokenInterceptor(tokenStorage: tokenStorage),
      // #12: feeds server Date headers to the skew estimator. Every
      // response through this Dio is a free calibration sample. LAST in
      // the stack, after TokenInterceptor: its send stamp is taken after
      // the async token-storage read — the only non-trivial latency in
      // the chain — so the measured round trip excludes it.
      ClockSkewInterceptor(recorder: clock),
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

  // #97: the per-server feedback transport. Registered here — not in its
  // own installer — per the registration convention: services sharing a
  // per-server resource register in that resource's installer, and this
  // shares the per-server Dio (which carries the base URL and the
  // BetterAuth session the feedback endpoint requires). Const and
  // stateless; nothing to dispose (the container owns the Dio).
  container.registerSingleton<FeedbackTransport>(FeedbackDioTransport(dio));
}
