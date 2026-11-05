import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/src/network/route_suffixes.dart';
import 'package:dio/dio.dart';

/// Answers a [RecordedRequest] with a [ScriptedResponse], now or later.
typedef ScriptedAnswer = FutureOr<ScriptedResponse> Function(
  RecordedRequest request,
);

/// One scripted answer: a body, a status and any extra headers.
///
/// The content type is always `application/json`; [headers] is merged over it.
class ScriptedResponse {
  /// Answers [body] verbatim with [status].
  const ScriptedResponse(
    this.body, {
    this.status = 200,
    this.headers = const {},
  });

  /// Answers [value] encoded as JSON with [status].
  ScriptedResponse.json(Object? value, {int status = 200})
    : this(jsonEncode(value), status: status);

  /// The response body, as sent over the wire.
  final String body;

  /// The HTTP status.
  final int status;

  /// Headers merged over the `application/json` content type.
  final Map<String, List<String>> headers;
}

/// A request as the server saw it.
class RecordedRequest {
  /// Captures a request in the shape tests assert against.
  RecordedRequest({
    required this.method,
    required this.path,
    required this.queryParameters,
    required this.headers,
    required this.data,
  });

  /// The upper-case HTTP method.
  final String method;

  /// The request's `options.path`, as written by the caller.
  final String path;

  /// The query parameters passed alongside [path].
  final Map<String, dynamic> queryParameters;

  /// The headers, as sent. Keys compare case-insensitively, as Dio's do.
  final Map<String, dynamic> headers;

  /// The request body: `options.data`, except that a `String` which parses as
  /// JSON is stored decoded, as whatever JSON value it holds (a `Map`, a
  /// `List`, a number, a bool, a string or null). Any other string stays as-is.
  final Object? data;

  /// The `Authorization` header, if one was sent.
  String? get authorization => headers['Authorization'] as String?;
}

/// A fake server behind an [HttpClientAdapter] that routes by method and path
/// suffix, records every request, and can hold or drop an answer.
///
/// It sits beside `RoutingAdapter` rather than replacing it. `RoutingAdapter`
/// is a stateless table of canned answers for transport-level cases; this is
/// a recorder for root-level tests, which need to ask what was sent, to hold
/// a response open while the app changes state around it, and to make an
/// answer never arrive.
///
/// Imports no `dart:io`, so a browser suite can use it unchanged.
class ScriptedServer implements HttpClientAdapter {
  final Map<(String, String), ScriptedAnswer> _routes = {};
  final List<RecordedRequest> _requests = [];
  final List<RecordedRequest> _unrouted = [];

  /// Answers [method] requests whose path ends with [pathSuffix].
  ///
  /// Re-registering the same method and suffix replaces the route. Asserts
  /// that no other route for [method] has a suffix that ends with this one,
  /// or the other way round, as `RoutingAdapter` does.
  void on(String method, String pathSuffix, ScriptedAnswer answer) {
    final key = (method.toUpperCase(), pathSuffix);
    assert(
      !_routes.keys.any((k) => k.$1 == key.$1 && suffixesOverlap(k.$2, key.$2)),
      'ambiguous routes: one suffix of $method is a suffix of another, so a '
      'path matching both would be decided by registration order.',
    );
    _routes[key] = answer;
  }

  /// Answers with [body] encoded as JSON and [status].
  void json(
    String method,
    String pathSuffix,
    Object? body, {
    int status = 200,
  }) => on(
    method,
    pathSuffix,
    (_) => ScriptedResponse.json(body, status: status),
  );

  /// Records the request, then answers when [release] completes.
  ///
  /// Every request to the route awaits the same [release], so one arriving
  /// after it completed is answered at once.
  void hold(
    String method,
    String pathSuffix,
    Future<ScriptedResponse> release,
  ) => on(method, pathSuffix, (_) => release);

  /// Records the request, then throws a `connectionError`: the request
  /// reached the server, and its answer never came back.
  void drop(String method, String pathSuffix) => on(
    method,
    pathSuffix,
    (_) => throw const _Dropped(),
  );

  /// Every request since the last [clear], in arrival order, including
  /// those no route answered.
  List<RecordedRequest> get requests => List.unmodifiable(_requests);

  /// Every request no route answered, in arrival order, for the server's
  /// whole life. Also in [requests] until a [clear], which leaves this list
  /// alone: it records failures, not traffic to count, so a clear before a
  /// measured step cannot hide one sent before it.
  List<RecordedRequest> get unrouted => List.unmodifiable(_unrouted);

  /// The recorded requests with [method] to a path ending with [pathSuffix].
  List<RecordedRequest> requestsTo(String method, String pathSuffix) =>
      _requests
          .where(
            (r) =>
                r.method == method.toUpperCase() &&
                _stripQuery(r.path).endsWith(pathSuffix),
          )
          .toList();

  /// Forgets the recorded [requests]; keeps the routes and [unrouted].
  void clear() => _requests.clear();

  static Map<String, dynamic> _caseInsensitive(Map<String, dynamic> source) =>
      LinkedHashMap<String, dynamic>(
        equals: (a, b) => a.toLowerCase() == b.toLowerCase(),
        hashCode: (k) => k.toLowerCase().hashCode,
      )..addAll(source);

  static String _stripQuery(String path) {
    final i = path.indexOf('?');
    return i < 0 ? path : path.substring(0, i);
  }

  static Object? _decode(Object? data) {
    if (data is! String) return data;
    try {
      return jsonDecode(data);
    } on FormatException {
      return data;
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final method = options.method.toUpperCase();
    final request = RecordedRequest(
      method: method,
      path: options.path,
      queryParameters: Map.of(options.queryParameters),
      headers: _caseInsensitive(options.headers),
      data: _decode(options.data),
    );
    _requests.add(request);

    final path = _stripQuery(options.path);
    ScriptedAnswer? answer;
    for (final entry in _routes.entries) {
      if (entry.key.$1 == method && path.endsWith(entry.key.$2)) {
        answer = entry.value;
        break;
      }
    }
    if (answer == null) {
      _unrouted.add(request);
      throw StateError('no scripted route for $method ${options.path}');
    }

    final ScriptedResponse response;
    try {
      response = await answer(request);
    } on _Dropped {
      throw DioException(
        type: DioExceptionType.connectionError,
        requestOptions: options,
      );
    }
    return ResponseBody.fromString(
      response.body,
      response.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...response.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Dropped implements Exception {
  const _Dropped();
}
