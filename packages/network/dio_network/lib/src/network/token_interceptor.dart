import 'package:di/di.dart' show LocalClockService;
import 'package:dio/dio.dart';
import 'package:interfaces/services.dart' show ClockService;

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
///
/// ## Expiry gating (#98)
///
/// The stored expiry became nullable when the client stopped fabricating one
/// at sign-in. Null means **unknown**, and unknown must still be sent: the
/// window between a sign-in and the `getSession` that confirms an expiry is
/// exactly when the app is busiest, and refusing to attach the token there
/// would break the reconcile call that fills the value in — a deadlock.
/// [StoredSession.isExpiredAt] encodes this: it is true only for a
/// *known-dead* session.
///
/// The check itself is a courtesy that saves a doomed round trip; the server
/// is the authority either way. It reads the per-server [ClockService] so a
/// device with a skewed clock does not discard a live token (or send a dead
/// one) purely on the strength of being wrong about the time.
class TokenInterceptor extends Interceptor {
  TokenInterceptor({
    required this._tokenStorage,
    this._clock = const LocalClockService(),
  });

  final TokenStorageService _tokenStorage;

  /// Per-server clock. Defaults to the [LocalClockService] null object so a
  /// host without a skew source is still correct (just uncorrected); the
  /// production composition in `registerServerNetwork` always injects the
  /// server's own estimator.
  final ClockService _clock;

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
    if (stored != null && !stored.isExpiredAt(_clock.nowUtc())) {
      options.headers['Authorization'] = 'Bearer ${stored.token}';
    }

    handler.next(options);
  }
}
