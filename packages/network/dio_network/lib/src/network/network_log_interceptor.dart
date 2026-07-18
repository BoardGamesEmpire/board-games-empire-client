import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:observability/observability.dart';

import 'redact_uri.dart';

/// Permanent network observability interceptor (#100), replacing the
/// temporary `DevLogInterceptor` (#101).
///
/// Installed first in every per-server Dio stack so it observes each
/// outgoing request and its resolution. Redaction is strict and
/// non-negotiable: it logs the method, the fully resolved URI (baseUrl +
/// path) with query, fragment, and userInfo stripped (see [redactUri]),
/// and either the response status or the transport error type — and NEVER
/// request/response bodies, headers, query parameters, passwords, or
/// tokens.
///
/// Levels follow the #100 buckets. Note the per-server Dio sets
/// `validateStatus: (_) => true`, so a 4xx/5xx comes back as a normal
/// [Response] (it never throws) — the levels are split accordingly:
/// - request/response at **debug**, gated by [traceRequests] (default:
///   non-release builds), so a product build's console and breadcrumb ring
///   are not flooded with a line per request;
/// - a **5xx** response at **warn**, always (ungated) — a genuine server
///   fault that must survive a release build, where the debug trace is
///   suppressed;
/// - a **transport-layer failure** — no response at all (connection
///   refused/reset, DNS, TLS) or a timeout — at **error**, always. That is
///   the seam that used to vanish silently (a "backend saw no connection"
///   symptom with nothing logged).
///
/// 4xx responses are deliberately left to the debug trace plus the feature
/// layer's semantic logging (e.g. `AuthBloc` categorises a 401 as an
/// invalid-credentials warning), so expected rejections are not
/// double-logged at the transport layer.
class NetworkLogInterceptor extends Interceptor {
  NetworkLogInterceptor({BgeLogger? logger, bool? traceRequests})
    : _logger = logger ?? BgeLogger('bge.network'),
      _traceRequests = traceRequests ?? !kReleaseMode;

  final BgeLogger _logger;
  final bool _traceRequests;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_traceRequests) {
      _logger.debug(
        'HTTP request',
        context: {
          'method': options.method,
          // Resolved absolute URI, redacted. baseUrl/path are deliberately
          // NOT logged verbatim: baseUrl can carry userInfo and a
          // hand-appended path can carry a query string, either of which
          // would breach the redaction contract.
          'uri': redactUri(options.uri),
        },
      );
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final status = response.statusCode;
    if (status != null && status >= 500) {
      // A 5xx arrives here (not onError) because the factory sets
      // validateStatus:(_)=>true. Log it at warn, ALWAYS — this is the
      // failed-response signal that must survive a release build, where the
      // debug request/response trace is suppressed.
      _logger.warn(
        'HTTP server error response',
        context: {
          'method': response.requestOptions.method,
          'uri': redactUri(response.requestOptions.uri),
          'status': status,
        },
      );
    } else if (_traceRequests) {
      _logger.debug(
        'HTTP response',
        context: {
          'method': response.requestOptions.method,
          'uri': redactUri(response.requestOptions.uri),
          'status': status,
        },
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // Transport-level failures ONLY: no response at all (connection
    // refused/reset, DNS, TLS) or a timeout. HTTP error *responses* (4xx/
    // 5xx) do NOT reach here — the factory sets validateStatus:(_)=>true,
    // so they arrive through onResponse (5xx logged there at warn).
    _logger.error(
      'HTTP transport failure (no response)',
      // Log the underlying transport error (e.g. a SocketException), NOT
      // the DioException itself: it carries RequestOptions — headers
      // (including the bearer token) and body — which a verbose sink could
      // serialise, breaching the redaction contract. The failure kind is
      // surfaced via dio_error_type.
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
