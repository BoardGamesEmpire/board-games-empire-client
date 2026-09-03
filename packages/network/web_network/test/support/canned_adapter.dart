import 'dart:typed_data';

import 'package:dio/dio.dart';

// COPY. The original is
// `packages/network/dio_network/test/support/canned_adapter.dart`; this file
// must stay in step with it.
//
// Copied rather than shared because a package's `test/` tree is not importable
// from another package, even though `web_network` already path-depends on
// `dio_network`. #352 D1 took that call deliberately and filed #354 to extract
// both copies into a shared test-support package.

/// An [HttpClientAdapter] that replays a canned body and status.
///
/// Exists because the mocktail `MockDio` the rest of these suites use stubs
/// `Dio.get`/`Dio.post` themselves, which means **Dio's own body cast never
/// runs**. That cast is the mechanism behind #265 and #182: asking Dio for
/// `Response<Map<String, dynamic>>` makes it cast the decoded body before the
/// caller sees anything, so a 2xx whose body is not a JSON object throws from
/// inside the call rather than reaching the caller's own checks.
///
/// A stubbed `Dio` cannot reproduce that — it returns whatever the stub was
/// given, correctly typed by construction — so a suite built only on `MockDio`
/// will pass against the bug. Swapping the adapter underneath a **real** [Dio]
/// keeps the whole pipeline (transformer, cast, `assureDioException`) in play
/// and lets these tests pin the real behaviour.
class CannedAdapter implements HttpClientAdapter {
  CannedAdapter({
    required this.body,
    required this.statusCode,
    this.contentType = Headers.jsonContentType,
  });

  final String body;
  final int statusCode;
  final String contentType;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    statusCode,
    headers: {
      Headers.contentTypeHeader: [contentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// A real [Dio] whose transport is replaced by a [CannedAdapter].
///
/// [permissiveStatus] mirrors `WellKnownClientImpl`'s own
/// `validateStatus: (_) => true`, under which Dio hands every status back as a
/// [Response] rather than throwing. Pass `false` to get Dio's default, where a
/// non-2xx throws `DioException.badResponse` **with the response attached** —
/// the shape an injected `Dio` can produce.
Dio cannedDio({
  required String body,
  required int statusCode,
  String contentType = Headers.jsonContentType,
  bool permissiveStatus = true,
}) =>
    Dio(
        BaseOptions(
          validateStatus: permissiveStatus ? (_) => true : null,
          followRedirects: false,
        ),
      )
      ..httpClientAdapter = CannedAdapter(
        body: body,
        statusCode: statusCode,
        contentType: contentType,
      );

/// A real [Dio] whose transport always fails the way an unreachable host does.
Dio unreachableDio(DioExceptionType type) =>
    Dio()..httpClientAdapter = _FailingAdapter(type);

class _FailingAdapter implements HttpClientAdapter {
  _FailingAdapter(this.type);
  final DioExceptionType type;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException(type: type, requestOptions: options);

  @override
  void close({bool force = false}) {}
}
