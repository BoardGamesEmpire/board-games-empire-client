import 'package:dio/dio.dart';

/// Builds per-server [Dio] instances with a consistent base configuration and
/// a caller-supplied interceptor stack.
///
/// The factory is intentionally agnostic about what its interceptors do — the
/// per-server DI container composes the stack (token attachment, telemetry,
/// dev logging, error translation, the future analytics sink) and passes it
/// in. Cross-cutting concerns register against the factory, never inside a
/// repository.
///
/// The base URL is the user-supplied server URL (`ServerConfig.serverUrl`), not
/// the server's self-declared `issuer` — endpoints are resolved relative to the
/// base the user actually configured. Endpoint paths sourced from the
/// well-known document are relative and resolve against this base.
abstract class DioFactory {
  /// Builds a [Dio] for the server reachable at [baseUrl], attaching
  /// [interceptors] in order.
  Dio buildForServer({
    required String baseUrl,
    List<Interceptor> interceptors = const [],
  });
}

/// Mobile/desktop [DioFactory]: bearer-token transport.
///
/// The web variant (`WebDioFactory` in `web_network`) overrides [BaseOptions]
/// to enable `withCredentials` and omits the token interceptor entirely, since
/// the browser manages the session cookie.
class DefaultDioFactory implements DioFactory {
  const DefaultDioFactory();

  @override
  Dio buildForServer({
    required String baseUrl,
    List<Interceptor> interceptors = const [],
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: normalizeBaseUrl(baseUrl),
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: const {'Accept': 'application/json'},
        // We inspect status codes ourselves rather than letting Dio throw.
        //
        // That only works if Dio also stays out of the response BODY. Ask it
        // for any type argument but `Response<String>` and a cast or a
        // `jsonDecode` it drives itself throws from inside the call as
        // `DioException(type: unknown)` with **no response attached** — the
        // status gone before anything can classify it, so a permanent
        // rejection reads as a transport fault and retries forever. Callers
        // read the body themselves via `decodeJsonBody`, whose doc carries the
        // rule and its one trap (#265, #182, #352, #358).
        validateStatus: (_) => true,
      ),
    );
    dio.interceptors.addAll(interceptors);
    return dio;
  }

  /// Strips a single trailing slash so relative endpoint paths (which begin
  /// with `/`) resolve without producing a double slash.
  static String normalizeBaseUrl(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
