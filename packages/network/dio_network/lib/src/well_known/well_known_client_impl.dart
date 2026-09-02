import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http_status/http_status.dart';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/decode_json_body.dart';

/// Dio-based implementation of [WellKnownClient].
///
/// Uses a dedicated [Dio] instance with no auth interceptors — the
/// /.well-known/bge-identity endpoint is intentionally unauthenticated and
/// must remain so. Never share this instance with authenticated API clients.
class WellKnownClientImpl implements WellKnownClient {
  WellKnownClientImpl() : _dio = _buildDio();

  /// Testing constructor. Inject a pre-configured [Dio] (e.g. with a mock
  /// adapter) instead of the production instance.
  @visibleForTesting
  WellKnownClientImpl.withDio(Dio dio) : _dio = dio;

  final Dio _dio;

  static Dio _buildDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: const {'Accept': 'application/json'},
      // Never follow redirects silently — URL changes require user confirmation
      followRedirects: false,
      validateStatus: (_) => true, // We handle status ourselves
    ),
  );

  @override
  Future<ServerIdentity> fetchIdentity(String serverUrl) async {
    final url = _buildWellKnownUrl(serverUrl);

    // `Response<String>` is the only type argument that keeps Dio out of the
    // body entirely (#182). `DioMixin.fetch` forces `responseType` from `T` —
    // `String` gives `plain`, and **anything else, `Object?` included, gives
    // `json`** (`dio_mixin.dart:417-427`) — and each half of Dio's own
    // handling loses the answer:
    //
    // * asking for `Response<Map<String, dynamic>>` makes Dio cast the decoded
    //   body before this method sees it, so an HTML page throws a `TypeError`;
    // * asking for anything non-`String` makes Dio `jsonDecode` any body whose
    //   **content type** claims JSON, so an HTML page served as
    //   `application/json`, or a truncated JSON document, throws a
    //   `FormatException`.
    //
    // Both escape as `DioException(type: unknown)` with **no response
    // attached**, land in the catch below, and are reported as *unreachable* —
    // telling the user to check their connection about a server that answered
    // perfectly well.
    //
    // This is the single most likely first-run mistake: point the app at an
    // ordinary website and it answers `/.well-known/bge-identity` with an HTML
    // page — 200 from an SPA catch-all, 404 from a plain web server. The
    // contract requires "that is not a BGE server", which needs the status and
    // the body read *after* the transport has succeeded, not during it.
    final Response<String> response;
    try {
      response = await _dio.get<String>(url);
    } on DioException catch (e) {
      // A DioException carrying a response means the server answered and this
      // Dio simply rejected the status — not the same thing as unreachable.
      // The production instance sets `validateStatus: (_) => true` so this
      // cannot fire, but the class accepts any injected Dio and must not call
      // an answered request a transport failure.
      final answered = e.response;
      if (answered != null) {
        return await _interpret(
          statusCode: answered.statusCode,
          body: answered.data,
          url: url,
          serverUrl: serverUrl,
          cause: e,
        );
      }
      throw WellKnownUnreachableException(
        serverUrl: serverUrl,
        message: _dioErrorMessage(e),
        cause: e,
      );
    }

    return _interpret(
      statusCode: response.statusCode,
      body: response.data,
      url: url,
      serverUrl: serverUrl,
      cause: null,
    );
  }

  /// Turns an answered request into a [ServerIdentity] or the typed failure
  /// the contract requires.
  ///
  /// Status decides first: it is the only part of the answer that is
  /// meaningful regardless of what the body turned out to be.
  Future<ServerIdentity> _interpret({
    required int? statusCode,
    required Object? body,
    required String url,
    required String serverUrl,
    required Object? cause,
  }) async {
    if (statusCode == HttpStatusCode.notFound) {
      throw WellKnownNotFoundException(
        serverUrl: serverUrl,
        message:
            'No BGE identity document found at $url. '
            'Verify the server URL or confirm this is a BGE instance.',
      );
    }

    if (statusCode != HttpStatusCode.ok) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Unexpected HTTP $statusCode from $url',
        statusCode: statusCode,
        cause: cause,
      );
    }

    // `body` is `Object?`, not `String?`, on purpose. This method is also
    // reached from the catch above with `DioException.response`, which is a
    // `Response<dynamic>` — an injected Dio using `responseType.bytes`/`stream`
    // (which `DioMixin.fetch` leaves alone) or an interceptor rejecting with an
    // already-decoded body can put a non-String there. Narrowing here keeps
    // that a typed `WellKnownException` instead of an implicit downcast that
    // would throw a raw `TypeError` out of the very branch added to stop an
    // answered server being misreported.
    final Object? decoded;
    if (body is String) {
      if (body.isEmpty) {
        throw WellKnownInvalidResponseException(
          serverUrl: serverUrl,
          message: 'Empty response body from $url',
          statusCode: HttpStatusCode.ok,
        );
      }
      try {
        decoded = await decodeJsonBody(body);
      } on FormatException catch (e) {
        throw WellKnownInvalidResponseException(
          serverUrl: serverUrl,
          message:
              'Response body from $url is not JSON, so this is not a BGE '
              'identity document. Confirm this URL is a BGE instance.',
          statusCode: HttpStatusCode.ok,
          cause: e,
        );
      } on Object catch (e) {
        // Decoding could not be performed — `decodeJsonBody` hands a large body
        // to another isolate and the spawn failed. That says nothing about the
        // server, so it must not become `WellKnownInvalidResponseException`:
        // that reads as "this is not a BGE server" and would send a user away
        // from a URL that is perfectly correct.
        //
        // `Unreachable` is the least-wrong bucket of the three — it is the
        // retryable one, and retrying is exactly the right advice for a
        // momentary local failure. Recorded as a deliberate choice rather than
        // a natural fit: nothing here failed at the network layer.
        //
        // This clause exists because decoding moved out from under the
        // `on DioException` net when the body became a `String`; without it a
        // raw exception escapes a method documented to throw only
        // `WellKnownException`.
        throw WellKnownUnreachableException(
          serverUrl: serverUrl,
          message: 'Could not read the response from $url. Please try again.',
          cause: e,
        );
      }
    } else {
      // Already decoded (or absent) — take it as it stands and let the shape
      // check below have the last word.
      decoded = body;
    }

    if (decoded == null) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Empty response body from $url',
        statusCode: HttpStatusCode.ok,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message:
            'Response body from $url is not a BGE identity document '
            '(expected a JSON object, got ${decoded.runtimeType}). '
            'Confirm this URL is a BGE instance.',
        statusCode: HttpStatusCode.ok,
      );
    }

    try {
      return ServerIdentity.fromJson(decoded);
    } on FormatException catch (e) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Failed to parse BGE identity document: ${e.message}',
        statusCode: HttpStatusCode.ok,
        cause: e,
      );
    } catch (e) {
      throw WellKnownInvalidResponseException(
        serverUrl: serverUrl,
        message: 'Unexpected error parsing BGE identity document: $e',
        statusCode: HttpStatusCode.ok,
        cause: e,
      );
    }
  }

  /// Builds the absolute well-known URL, normalizing trailing slashes.
  String _buildWellKnownUrl(String serverUrl) {
    final base = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;
    return '$base/.well-known/bge-identity';
  }

  String _dioErrorMessage(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout =>
      'Connection timed out. Check the server URL and network.',
    DioExceptionType.receiveTimeout => 'Server took too long to respond.',
    DioExceptionType.connectionError =>
      'Unable to reach server. Check the URL and your connection.',
    _ => e.message ?? 'Network error: ${e.type}',
  };
}
