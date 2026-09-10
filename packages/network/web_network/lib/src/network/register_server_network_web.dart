import 'package:di/di.dart' show ServerSkewClockService;
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show
        ClockSkewInterceptor,
        DioFactory,
        FeedbackDioTransport,
        HouseholdRemoteDataSourceImpl,
        NetworkLogInterceptor;
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart' show ClockService;
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart'
    show HouseholdRemoteDataSource;
import 'package:observability/observability.dart' show FeedbackTransport;

import '../auth/web_auth_repository_impl.dart';
import 'web_clock_skew_diagnostic_interceptor.dart';
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
/// The skew-corrected clock (#118) is registered here rather than in a
/// clock-specific installer, for the same reason as the native leg: the
/// estimator is fed by *this* Dio's responses, so it belongs beside the
/// transport that feeds it.
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

  // #118: per-server skew-corrected clock, fed by the `Date` header on this
  // origin's responses. Registered under the read interface only — the feed
  // surface (`ClockSkewRecorder`) goes straight to the interceptor below, so
  // consumers cannot reach the ingestion API (ISP, as on native).
  //
  // Same-origin is what makes this readable at all: `originProvider` is the
  // browser's own address bar, and `Date` is hidden from JavaScript only on
  // *cross-origin* responses that omit `Access-Control-Expose-Headers: Date`
  // (a backend change needed only if a cross-origin deployment ever appears).
  // Where the header is unreadable the estimate stays `null` and `nowUtc()`
  // returns the raw local clock — the supported degraded state, not an error.
  final clock = ServerSkewClockService();
  container.registerSingleton<ClockService>(
    clock,
    dispose: (_) => clock.dispose(),
  );

  final dio = factory.buildForServer(
    baseUrl: originProvider(),
    interceptors: [
      // #282: permanent network observability, first of the three installed
      // here so it observes every outgoing request and its resolution — the
      // same placement and the same rationale as native's. (Dio still seeds
      // its own `ImplyContentTypeInterceptor` ahead of all of them, on both
      // platforms.) Redaction-safe — method, resolved URI, and status or
      // error type only — and self-gating to non-release builds for the
      // request trace, so nothing web-specific is needed. Web had none of
      // this: until now the browser stack kept no record of any request it
      // made.
      NetworkLogInterceptor(),
      // #118: every response through this Dio is a free calibration sample,
      // so no dedicated calibration request is ever needed. Native installs
      // this last, behind `TokenInterceptor`, so its send stamp excludes the
      // async token-storage read; on web there is nothing async to sit behind
      // — the browser attaches the cookie itself, and the log interceptor
      // above is synchronous — so the stamp is still taken immediately
      // before dispatch.
      ClockSkewInterceptor(recorder: clock),
      // #281: reports once if this origin's responses carry no readable
      // `Date`, which on web means a misconfiguration rather than the benign
      // absence it is on native. It observes only — the shared feeder above
      // stays silent, and the condition is invisible to the registered clock,
      // which never hears about a response it took no sample from.
      WebClockSkewDiagnosticInterceptor(),
    ],
  );
  container.registerSingleton<Dio>(dio, dispose: (_) => dio.close());

  final authRepository = WebAuthRepositoryImpl(identity: identity, dio: dio);
  container.registerSingleton<AuthRepository>(
    authRepository,
    dispose: (_) => authRepository.onDispose(),
  );

  // #97: the per-server feedback transport, sharing this origin's Dio —
  // the browser attaches the httpOnly session cookie the feedback
  // endpoint requires, so `FeedbackDioTransport` needs nothing
  // web-specific. Same installer-placement rationale as the native leg.
  container.registerSingleton<FeedbackTransport>(FeedbackDioTransport(dio));

  // #125: the per-origin household remote. Same convention and the same
  // placement as the feedback transport above and as native's registration —
  // it shares this origin's Dio (base URL + the browser-owned session cookie
  // the `/api/households` endpoints require) and adds no auth of its own.
  // Const and stateless; the container owns the Dio.
  //
  // Native's implementation, not a web twin: it takes an injected Dio and
  // nothing in it is platform-specific. Its two load-bearing assumptions hold
  // here — `decodeJsonBody` offloads through `compute`, which runs inline on
  // web, and its status classification needs the permissive `validateStatus`
  // that `WebDioFactory` sets exactly as the native factory does. Keeping one
  // implementation is what makes the 403 envelope rule (#350, #365) a single
  // rule rather than two that drift.
  container.registerSingleton<HouseholdRemoteDataSource>(
    HouseholdRemoteDataSourceImpl(dio),
  );
}
