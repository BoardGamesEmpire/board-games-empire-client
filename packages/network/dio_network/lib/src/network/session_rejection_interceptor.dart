import 'package:dio/dio.dart';
import 'package:http_status/http_status.dart';
import 'package:observability/observability.dart';

final BgeLogger _log = BgeLogger('bge.auth.session_rejection');

/// Reports a 401 from any non-auth endpoint of the server (#484).
///
/// A data endpoint answering 401 means the server no longer honours the
/// session, but nothing in a remote's own failure mapping reaches auth
/// state. Installed on the per-server Dio, shared by the auth repository and
/// every remote, this raises `onRejected` once per such response; the
/// callback (a `SessionRejectionSignal.report`) decides whether the session
/// is really gone.
///
/// Requests under `authBase` are skipped: `getSession`'s own 401 is how the
/// session read says "signed out", and reporting it would revalidate in a
/// loop. "Under" means the same origin and a path equal to, or below, the
/// auth base's path, compared by whole segments (`/api/auth` covers
/// `/api/auth/get-session` but not `/api/authors`).
///
/// The per-server Dio accepts every status, so a 401 normally arrives in
/// `onResponse`; `onError` covers a Dio whose `validateStatus` rejects it.
/// Either way the response or error is passed on unchanged, and a throwing
/// `onRejected` never breaks the request.
final class SessionRejectionInterceptor extends Interceptor {
  /// Creates the interceptor.
  ///
  /// `authBase` is the auth API's base URI (for example
  /// `https://host/api/auth`). `onRejected` is called synchronously for each
  /// qualifying 401.
  SessionRejectionInterceptor({
    required Uri authBase,
    required this._onRejected,
  }) : _authBase = authBase,
       _authPath = _withoutTrailingSlashes(authBase.path);

  final Uri _authBase;
  final String _authPath;
  final void Function() _onRejected;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _check(response);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final response = err.response;
    if (response != null) _check(response);
    handler.next(err);
  }

  void _check(Response<dynamic> response) {
    if (response.statusCode != HttpStatusCode.unauthorized) return;
    if (_isUnderAuthBase(response.requestOptions.uri)) return;

    try {
      _onRejected();
    } on Object catch (error, stackTrace) {
      _log.warn(
        'Reporting a rejected session failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _isUnderAuthBase(Uri uri) {
    if (uri.scheme != _authBase.scheme ||
        uri.host != _authBase.host ||
        uri.port != _authBase.port) {
      return false;
    }

    final path = _withoutTrailingSlashes(uri.path);
    return path == _authPath || path.startsWith('$_authPath/');
  }

  static String _withoutTrailingSlashes(String path) {
    var end = path.length;
    while (end > 0 && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }
}
