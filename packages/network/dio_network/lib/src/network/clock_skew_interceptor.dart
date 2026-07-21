import 'dart:io';

import 'package:dio/dio.dart';
import 'package:interfaces/services.dart';

/// Feeds server `Date` headers to the per-server [ClockSkewRecorder]
/// (#12).
///
/// Lives in the shared interceptor stack built by `DioFactory`, so every
/// repository sharing the server's [Dio] contributes skew samples for
/// free — the `Date` header is HTTP-spec mandatory on most responses, so
/// no dedicated calibration request is ever needed.
///
/// [onRequest] stamps the raw local send time into [RequestOptions.extra]
/// under [sentAtKey]; [onResponse] pairs it with the raw local receive
/// time and the parsed `Date` header and reports one sample. The
/// estimator (not this interceptor) owns midpoint math, smoothing, and
/// sample hygiene — this class only extracts and forwards.
///
/// ## Measurement window
///
/// Installed **last** in the interceptor stack, so the send stamp is
/// taken after `TokenInterceptor`'s async token-storage read — the only
/// non-trivial pre-dispatch latency — and immediately before Dio hands
/// the request to the adapter. Residual widening of the measured window
/// (serialization, TCP dispatch) is sub-millisecond and shifts the
/// midpoint slightly *earlier* than the server's `Date` generation
/// instant, a systematic error orders of magnitude below both the
/// header's one-second resolution and the estimator's correction
/// deadband — this service targets minute-scale skew, not NTP-grade
/// precision.
///
/// Responses without a `Date` header, with an unparsable value, or whose
/// request somehow lost its send stamp are skipped silently: absence of
/// a sample is a supported state ([ClockService.skewEstimate] stays
/// `null` and the local clock is used uncorrected).
///
/// `onError` is deliberately not overridden: the per-server Dio sets
/// `validateStatus: (_) => true`, so every HTTP response — including
/// 4xx/5xx — arrives through [onResponse]; only transport failures
/// (which carry no headers) reach the error path.
///
/// Native-only (`dart:io` [HttpDate]); the web stack gets its own feeder
/// (#118).
class ClockSkewInterceptor extends Interceptor {
  /// Creates the interceptor.
  ///
  /// [nowUtc] injects the raw local clock for tests; production uses
  /// `DateTime.now().toUtc()`. Stamps are deliberately the **raw**
  /// clock, never [ClockService.nowUtc] — the estimator compares raw
  /// local time to server time, and correcting the inputs with the
  /// output would feed the estimate back into itself.
  ClockSkewInterceptor({
    required ClockSkewRecorder recorder,
    DateTime Function()? nowUtc,
  }) : _recorder = recorder,
       _nowUtc = nowUtc ?? _systemNowUtc;

  static DateTime _systemNowUtc() => DateTime.now().toUtc();

  /// [RequestOptions.extra] key carrying the raw local UTC send stamp.
  static const String sentAtKey = 'bge_clock_skew_sent_at';

  final ClockSkewRecorder _recorder;
  final DateTime Function() _nowUtc;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Re-stamped on every pass, so a retried request measures its own
    // round trip rather than the original attempt's.
    options.extra[sentAtKey] = _nowUtc();
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _record(response);
    handler.next(response);
  }

  void _record(Response<dynamic> response) {
    final header = response.headers.value(HttpHeaders.dateHeader);
    if (header == null) return;

    final sentAt = response.requestOptions.extra[sentAtKey];
    if (sentAt is! DateTime) return;

    final DateTime serverDate;
    try {
      serverDate = HttpDate.parse(header);
    } on Exception {
      // Malformed Date header: skip the sample. HttpDate.parse throws
      // HttpException; the broader catch also covers FormatException
      // should the implementation change.
      return;
    }

    _recorder.recordSample(
      serverDate: serverDate,
      requestSentAt: sentAt,
      responseReceivedAt: _nowUtc(),
    );
  }
}
