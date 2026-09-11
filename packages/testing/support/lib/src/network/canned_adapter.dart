import 'dart:typed_data';

import 'package:dio/dio.dart';

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
  /// Replays [body] with [statusCode], labelled [contentType].
  CannedAdapter({
    required this.body,
    required this.statusCode,
    this.contentType = Headers.jsonContentType,
  });

  /// The response body, replayed verbatim for every request.
  ///
  /// Deliberately a `String` rather than a decoded object: the point of this
  /// adapter is that Dio's own transformer and cast run over raw bytes, so a
  /// body that is not valid JSON — or is valid JSON of the wrong shape — has
  /// to be expressible here.
  final String body;

  /// The status Dio sees. Whether a non-2xx throws depends on the client's
  /// `validateStatus`, not on this value — see [cannedDio]'s
  /// `permissiveStatus`.
  final int statusCode;

  /// The `content-type` header sent with [body].
  ///
  /// Defaults to JSON. Setting it to something else while leaving [body] as
  /// JSON (or the reverse) is the point in the cases that turn on a body
  /// lying about its type.
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
///
/// Returns a *fresh* [Dio]. When the failure has to be installed on a [Dio]
/// that already exists — a suite asserting what a registered remote does with
/// the registered client — assign a [FailingAdapter] to that instance's
/// `httpClientAdapter` instead.
Dio unreachableDio(DioExceptionType type) =>
    Dio()..httpClientAdapter = FailingAdapter(type);

/// An [HttpClientAdapter] that always throws a [DioException] of [type]
/// carrying **no response**, the way an unreachable origin does.
///
/// Public, unlike the rest of this file's internals, because a suite may need
/// to install the failure on a [Dio] it did not construct — see
/// [unreachableDio].
class FailingAdapter implements HttpClientAdapter {
  /// Fails every request with a [DioException] of [type], optionally carrying
  /// [error] as its payload.
  FailingAdapter(this.type, {this.error});

  /// The failure classification Dio reports.
  final DioExceptionType type;

  /// Optional payload on the thrown [DioException]; `null` leaves it unset.
  final Object? error;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      throw DioException(type: type, requestOptions: options, error: error);

  @override
  void close({bool force = false}) {}
}
