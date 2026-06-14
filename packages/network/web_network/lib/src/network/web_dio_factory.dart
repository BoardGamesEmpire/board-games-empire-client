import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart' show DioFactory;

/// Web [DioFactory]: cookie-based transport.
///
/// Differs from `DefaultDioFactory` (mobile/desktop) in two ways:
/// - `withCredentials` is enabled so the browser sends the BetterAuth session
///   cookie on cross-origin requests.
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
        // Required for cross-origin cookie transmission in the browser.
        extra: const {'withCredentials': true},
      ),
    );
    dio.interceptors.addAll(interceptors);
    return dio;
  }

  static String _normalizeBaseUrl(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
