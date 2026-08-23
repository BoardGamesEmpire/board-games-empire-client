import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show DioFactory;

/// Web [DioFactory]: cookie-based transport.
///
/// Differs from `DefaultDioFactory` (mobile/desktop) in two ways:
/// - `withCredentials` is enabled: it is what opts a request into sending
///   credentials at all. Today the stack only talks to the browser's own
///   origin, where cookies are sent regardless, so it is not load-bearing.
/// - No token interceptor — the browser owns the opaque httpOnly cookie; Dart
///   never reads or attaches it. Any [interceptors] passed in are still
///   honored, but the web registration helper passes none.
///
/// On web the base URL comes from the browser's address bar via
/// [currentOrigin], not from `ServerConfig.serverUrl`.
class WebDioFactory implements DioFactory {
  const WebDioFactory();

  /// The browser's current origin (`scheme://host[:port]`) taken from the
  /// address bar. On web, [Uri.base] reflects `window.location`.
  static String currentOrigin() => Uri.base.origin;

  @override
  Dio buildForServer({
    required String baseUrl,
    List<Interceptor> interceptors = const [],
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: _normalizeBaseUrl(baseUrl),
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: const {'Accept': 'application/json'},
        // We inspect status codes ourselves rather than letting Dio throw.
        validateStatus: (_) => true,
        // Opts requests into sending credentials. NOT evidence that the
        // transport is cross-origin: `registerServerNetworkWeb` passes
        // [currentOrigin], so this Dio addresses the browser's own origin,
        // which sends cookies with or without the flag.
        // `WebAuthRepositoryImpl` reasons from same-origin in places, and
        // an earlier wording here read as a contradiction of that.
        //
        // Necessary but NOT sufficient for a cross-origin session: the
        // cookie's SameSite/Secure/Domain attributes and a credentialed
        // CORS configuration on the server all have to permit the exchange
        // too. This flag removes one obstacle, not the class of them — do
        // not read it as a cross-origin guarantee.
        extra: const {'withCredentials': true},
      ),
    );
    dio.interceptors.addAll(interceptors);
    return dio;
  }

  static String _normalizeBaseUrl(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
