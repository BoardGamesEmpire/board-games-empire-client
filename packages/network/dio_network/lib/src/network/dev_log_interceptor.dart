import 'package:dio/dio.dart';
import 'package:observability/observability.dart';

import 'redact_uri.dart';

/// TEMPORARY diagnostic interceptor (#101) — removed by #100.
///
/// Logs whether a request was actually attempted and how it resolved, so a
/// "backend saw no connection" symptom can be told apart from a rejected
/// response. Redaction is strict and non-negotiable: it logs the method,
/// the fully resolved URI (baseUrl + path), and either the response status
/// or the transport error type — and NEVER request/response bodies,
/// headers, query parameters, passwords, or tokens.
class DevLogInterceptor extends Interceptor {
  DevLogInterceptor({BgeLogger? logger})
    : _logger = logger ?? BgeLogger('bge.network.dev');

  final BgeLogger _logger;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _logger.debug(
      'HTTP request attempted',
      context: {
        'method': options.method,
        // The resolved absolute URI (baseUrl + path), with query, fragment,
        // and userInfo stripped (see [_redactUri]) — the redaction contract
        // in the class docs is non-negotiable. If baseUrl is empty or
        // malformed this is exactly where it shows: a missing scheme/host
        // means the baseUrl never resolved. baseUrl and path are deliberately
        // NOT logged verbatim alongside it — baseUrl can carry userInfo and
        // path can carry a hand-appended query string, either of which would
        // breach that contract (PR #103 review).
        'uri': redactUri(options.uri),
      },
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _logger.debug(
      'HTTP response received',
      context: {
        'method': response.requestOptions.method,
        'uri': redactUri(response.requestOptions.uri),
        'status': response.statusCode,
      },
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _logger.error(
      'HTTP request failed at transport layer (no/failed response)',
      // Log the underlying transport error (e.g. a SocketException), NOT the
      // DioException itself: a DioException carries its RequestOptions —
      // headers (including the bearer token) and body — which a verbose
      // formatter or sink could serialise, breaching the redaction contract.
      // The failure kind is still surfaced via dio_error_type (PR #103
      // review).
      error: err.error,
      stackTrace: err.stackTrace,
      context: {
        'method': err.requestOptions.method,
        'uri': redactUri(err.requestOptions.uri),
        'dio_error_type': err.type.name,
        'status': err.response?.statusCode,
      },
    );
    handler.next(err);
  }
}
