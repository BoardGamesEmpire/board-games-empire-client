import 'dart:typed_data';

import 'package:bge_test_support/src/network/canned_adapter.dart';
import 'package:dio/dio.dart';

/// An [HttpClientAdapter] that answers a canned body and status **per request
/// path**, which [CannedAdapter] cannot.
///
/// Exists for the cases where one call has to succeed while another fails: a
/// sign-in whose grant body is rejected while the session endpoint still
/// answers well, or a grant that succeeds while its reconcile is refused.
///
/// Every route is answered as `application/json`. That is deliberate rather
/// than an omission — these cases turn on a body that **lies** about its
/// content type, so letting a route understate its type would only let a case
/// understate the bug.
///
/// [CannedAdapter] is the single-response sibling; prefer it when one answer
/// will do.
class RoutingAdapter implements HttpClientAdapter {
  /// Answers each request with the entry in [byPathSuffix] whose key the
  /// request path ends with.
  ///
  /// Asserts that no key is a suffix of another. Resolving such a pair by
  /// declaration order would answer the wrong route with no warning, which in
  /// a test helper means a case that passes or fails for a reason its author
  /// never wrote down.
  RoutingAdapter(this.byPathSuffix)
    : assert(
        !_hasSuffixOverlap(byPathSuffix.keys),
        'ambiguous routes: one suffix is a suffix of another, so the path '
        'matching both would be decided by declaration order. Make the keys '
        'mutually exclusive.',
      );

  static bool _hasSuffixOverlap(Iterable<String> keys) {
    for (final a in keys) {
      for (final b in keys) {
        if (a != b && a.endsWith(b)) return true;
      }
    }
    return false;
  }

  /// Suffix → (body, status).
  ///
  /// **The first entry whose key the request path ends with wins**, in the
  /// map's insertion order. That only matters if one key is itself a suffix of
  /// another — `'session'` and `'/api/get-session'`, say, where a request to
  /// the latter matches both — and the assertion in the constructor rejects
  /// exactly that case, so declaration order can never silently decide a
  /// route. (`'/session'` and `'/get-session'` are *not* such a pair:
  /// `'/get-session'.endsWith('/session')` is false.)
  final Map<String, (String, int)> byPathSuffix;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    for (final entry in byPathSuffix.entries) {
      if (options.path.endsWith(entry.key)) {
        return ResponseBody.fromString(
          entry.value.$1,
          entry.value.$2,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
    }
    throw StateError('no canned answer for ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

/// A real [Dio] whose transport is replaced by a [RoutingAdapter].
///
/// [permissiveStatus] carries the same meaning, spelling and default it has on
/// `cannedDio`: `true` mirrors a `validateStatus: (_) => true` client, under
/// which Dio hands every status back as a [Response] rather than throwing.
/// Pass `false` for Dio's default, where a non-2xx throws
/// `DioException.badResponse` **with the response attached**.
///
/// The two copies this replaces disagreed on that default — `web_network`'s
/// took `permissive` defaulting to `true`, `dio_network`'s took no parameter at
/// all and so always got Dio's throwing default. Unifying on `cannedDio`'s
/// spelling and default means one name and one meaning across the package;
/// the `dio_network` call sites that relied on throwing now say
/// `permissiveStatus: false` where they always meant it (#354 D2).
Dio routingDio(
  Map<String, (String, int)> byPathSuffix, {
  bool permissiveStatus = true,
}) =>
    Dio(BaseOptions(validateStatus: permissiveStatus ? (_) => true : null))
      ..httpClientAdapter = RoutingAdapter(byPathSuffix);
