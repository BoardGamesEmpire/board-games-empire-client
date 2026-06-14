import 'package:dio/dio.dart';

import '../auth/token_storage_service.dart';

/// Attaches the per-server bearer token to outgoing requests.
///
/// Lives in the shared interceptor stack built by [DioFactory], not inside any
/// repository — so every repository sharing the server's [Dio] inherits token
/// attachment regardless of construction order.
///
/// Token attachment is the default. A request targeting a public endpoint can
/// opt out by setting [skipAuthKey] in [Options.extra]:
///
/// ```dart
/// dio.get(path, options: Options(extra: {TokenInterceptor.skipAuthKey: true}));
/// ```
class TokenInterceptor extends Interceptor {
  TokenInterceptor({required TokenStorageService tokenStorage})
    : _tokenStorage = tokenStorage;

  final TokenStorageService _tokenStorage;

  /// Request-level opt-out flag for [Options.extra]. When `true`, no
  /// Authorization header is attached even if a valid token is stored.
  static const String skipAuthKey = 'bge_skip_auth';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[skipAuthKey] == true) {
      handler.next(options);
      return;
    }

    final stored = await _tokenStorage.retrieve();
    if (stored != null && !stored.isExpired) {
      options.headers['Authorization'] = 'Bearer ${stored.token}';
    }

    handler.next(options);
  }
}
