import 'package:dio/dio.dart';
import 'package:network_interface/network_interface.dart' show tryParseHttpDate;
import 'package:observability/observability.dart' show BgeLogger;

/// Reports, once per server scope, that this origin's responses carry no
/// readable `Date` header — so the web scope is running on the uncorrected
/// local clock (#281).
///
/// ## Why this is a web-only concern
///
/// On native a missing `Date` is a benign absence: the estimate stays `null`,
/// `nowUtc()` returns the raw local clock, and that is a supported state. On
/// web it means something else. This stack addresses the browser's own origin
/// (`registerServerNetworkWeb` passes `WebDioFactory.currentOrigin`), where
/// `Date` is not CORS-filtered and the browser adapter reads it straight off
/// the response — so an unreadable one means something is actually
/// misconfigured: a cross-origin deployment without
/// `Access-Control-Expose-Headers: Date`, or an intermediary stripping it.
///
/// ## Why it lives in the transport rather than on the clock
///
/// The obvious-looking alternative — watch the registered `ClockService` and
/// treat an estimate that never leaves `null` as the signal — cannot work.
/// `ClockSkewInterceptor` returns early on a response with no parsable
/// `Date` and never calls `recordSample`, so the estimator is never told the
/// response happened. A `null` estimate is therefore indistinguishable
/// between three states: no traffic yet, traffic with no readable `Date`,
/// and traffic whose samples have not yet confirmed each other (the
/// estimator establishes nothing until two consecutive samples agree). Only
/// something watching responses can tell them apart.
///
/// ## What it does not do
///
/// It extracts no samples and records none: `ClockSkewInterceptor` stays
/// silent and unchanged on both platforms (#118 D4), and this class only
/// observes. What it does repeat, deliberately, is that interceptor's
/// readability check — see [_hasReadableDate].
///
/// `onError` is deliberately not overridden, for the same reason
/// `ClockSkewInterceptor` does not: the per-server Dio sets
/// `validateStatus: (_) => true`, so every HTTP response arrives through
/// [onResponse], and only transport failures — which carry no headers, and
/// so are no evidence either way — reach the error path.
class WebClockSkewDiagnosticInterceptor extends Interceptor {
  /// Creates the observer.
  ///
  /// The logger is fixed rather than injected: these records are asserted
  /// off `Logger.root` like every other log in this repo, so an injection
  /// seam would be API nothing uses.
  WebClockSkewDiagnosticInterceptor();

  /// Dio normalizes response header names to lowercase.
  static const String _dateHeader = 'date';

  final BgeLogger _logger = BgeLogger('bge.web.network.clock_skew');

  /// Responses seen with no readable `Date`, counting only those where the
  /// header is mandatory (see [_dateIsMandatory]), until [_answered].
  int _unreadable = 0;

  /// Whether the question is answered and nothing further will be logged —
  /// set by the first readable `Date`, or by the one warning this emits.
  bool _answered = false;

  /// Responses with no readable `Date` required before warning.
  ///
  /// **Two, not one.** A single omission is not evidence of a
  /// misconfiguration: an origin server without a clock must not send
  /// `Date` at all, so one absence can be a property of that response
  /// rather than of the deployment. Warning on it would report a fault
  /// that does not exist, and at [_logger]'s `warn` level the report
  /// survives into a feedback submission.
  ///
  /// The conditions this exists for apply to *every* response, so they
  /// still trip on the second request; the cost of the higher bar is one
  /// request's delay. Symmetric with the estimator this diagnoses, which
  /// likewise trusts no single sample.
  static const int _threshold = 2;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (!_answered) {
      if (_hasReadableDate(response)) {
        // Positive evidence, whatever the status: the origin exposes the
        // header, so there is nothing to report and never will be.
        _answered = true;
      } else if (_dateIsMandatory(response) && ++_unreadable >= _threshold) {
        _answered = true;
        // Warn, not debug, and ungated by build mode: the console sink's
        // release threshold is warn+, and warn records reach the breadcrumb
        // ring a feedback report carries. A misconfigured deployment is
        // exactly the condition a release build should still surface, and
        // one line cannot flood anything.
        _logger.warn(
          'No readable Date header on this origin; consensus timestamps run '
          'on the uncorrected local clock',
          context: {
            // The header as received, so a stripped header (null) and an
            // unparsable one are distinguishable in the report. Response
            // headers are not request material — no token or query string
            // can reach this.
            'date_header': response.headers.value(_dateHeader),
            'status': response.statusCode,
            'responses': _unreadable,
          },
        );
      }
    }
    handler.next(response);
  }

  /// Whether RFC 9110 requires a `Date` on a response with this status, and
  /// so whether its absence is evidence of anything.
  ///
  /// Only 2xx, 3xx and 4xx qualify. §6.6.1: an origin server with a clock
  /// "MUST generate a Date header field in all 2xx (Successful), 3xx
  /// (Redirection), and 4xx (Client Error) responses, and MAY generate a
  /// Date header field in 1xx (Informational) and 5xx (Server Error)
  /// responses". A 5xx without one is therefore conformant — a gateway's
  /// own error page during an outage is the ordinary case — and says
  /// nothing about whether this origin exposes the header. Counting those
  /// would report a misconfigured deployment on any run of server errors.
  ///
  /// A status Dio could not read is likewise not evidence.
  static bool _dateIsMandatory(Response<dynamic> response) {
    final status = response.statusCode;
    return status != null && status >= 200 && status < 500;
  }

  /// Whether [response] carries a `Date` the estimator could actually use.
  ///
  /// Repeats `ClockSkewInterceptor`'s header lookup and parse rather than
  /// sharing them, which is a real if small duplication — accepted so that
  /// "readable" cannot mean two different things: this must report exactly
  /// the responses that interceptor takes no sample from. Both go through
  /// [tryParseHttpDate], so an obsolete-format or malformed value is as
  /// unusable as a missing header in both places.
  bool _hasReadableDate(Response<dynamic> response) {
    final header = response.headers.value(_dateHeader);
    return header != null && tryParseHttpDate(header) != null;
  }
}
