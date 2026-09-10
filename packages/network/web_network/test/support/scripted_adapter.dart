import 'dart:typed_data';

import 'package:dio/dio.dart';

/// An [HttpClientAdapter] returning a canned 200 with scriptable response
/// headers, or throwing a scripted [DioException] to exercise the
/// transport-failure path.
///
/// Shared rather than restated per suite, following `server_identity_fixture`
/// (#125): the registration suite and the clock-skew diagnostic suite both
/// need a response whose headers they choose, and one of them also needs a
/// failure with no response at all.
///
/// Distinct from [CannedAdapter] (`test/support/canned_adapter.dart`), which
/// scripts a **body and status** to keep Dio's own decode-and-cast pipeline in
/// play. This one scripts **headers and transport failures** and always
/// returns an empty JSON object, because its suites are about what the
/// interceptor stack observes, not about what the body decodes to.
class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter({this.responseHeaders = const {}, this.error});

  /// Extra headers merged into the canned response.
  final Map<String, List<String>> responseHeaders;

  /// When set, [fetch] throws this instead of answering — a transport
  /// failure, which carries no response and therefore no headers.
  final DioException? error;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final failure = error;
    if (failure != null) throw failure;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...responseHeaders,
      },
    );
  }
}
