import 'package:dio/dio.dart';
import 'package:observability/observability.dart';

import '../network/decode_json_body.dart';

/// Concrete [FeedbackTransport] posting through a **per-server** Dio
/// instance (#69, #97).
///
/// Wire contract (backend `libs/api/feedback`): `POST /api/feedback/reports`
/// → 201. The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included), and the existing per-server auth
/// plumbing attaches the BetterAuth session the endpoint requires (CASL
/// `create:feedback_report`; feedback-banned users get 403; throttled at
/// 30/user/hour → 429). This class adds no auth handling of its own; it
/// is constructed from the per-server container by the network installer
/// and resolved via the active server's `FeedbackTargetResolver`.
///
/// ## Failure classification (#97)
///
/// Every failure is wrapped per the [FeedbackTransport] contract — the
/// service never sees a raw transport exception type — and classified:
///
/// - [FeedbackTransientSubmissionException] (**retryable**): connection
///   errors, all timeouts, cancellation, 401 (a session can expire
///   between resolve and send), 408, 429 (throttle — the drain stops
///   here), all 5xx, and any failure without a response status
///   (including certificate errors, which can be a captive portal —
///   discarding a user-approved report on one would be wrong), and a 2xx
///   whose body is present but unparseable, which means something other
///   than the API answered (#358 — see [_rejectUndecodableBody]).
/// - [FeedbackPermanentSubmissionException]: 400 (validation), 403
///   (feedback-banned), and every other 4xx — retrying can never
///   succeed, so the service must not queue these.
///
/// The status is read before the body is touched, so a rejection is
/// classified by what the server said rather than by whether Dio could
/// decode what it sent (#358).
class FeedbackDioTransport implements FeedbackTransport {
  const FeedbackDioTransport(this._dio);

  final Dio _dio;

  /// 4xx statuses that are nonetheless worth retrying: an expired
  /// session (401), a request timeout (408), and the throttle (429).
  static const Set<int> _retryable4xx = {401, 408, 429};

  @override
  Future<void> send(FeedbackReport report) async {
    try {
      // `String` keeps Dio out of the body, and this call site is the reason
      // the rule needs stating as more than "not `Map`" (#358). `dynamic` is
      // the one type argument that reaches `ResponseType.json` WITHOUT
      // entering `DioMixin.fetch`'s forcing block: the block is gated on
      // `T != dynamic` (`dio_mixin.dart:419-427`) and `BaseOptions` already
      // defaults to json (`options.dart:153`). So `post<dynamic>` still had
      // Dio `jsonDecode` any body whose *content type* claimed JSON, and a
      // `FormatException` from that decode escaped as
      // `DioException(type: unknown)` with **no response attached** — the
      // status gone before `_classifyDioException` could read it, so a
      // permanent 400 classified transient and retried forever.
      //
      // `responseType` is pinned rather than left to the injected Dio.
      // `fetch`'s forcing block is ALSO skipped when the instance is set to
      // `bytes`/`stream` (`dio_mixin.dart:419-421`), and then `assureResponse`
      // casts the body to `String` anyway (`:807`) — a `TypeError` from inside
      // the call, arriving as `DioException(type: unknown)` with no response.
      // That is this issue's own defect, reintroduced one configuration over.
      // `post<dynamic>` could not hit it because `dynamic` skips the cast, so
      // asking for `String` without pinning would have traded one exposure for
      // another. `WellKnownClientImpl` defends the same case at `:127-136`.
      final response = await _dio.post<String>(
        '/api/feedback/reports',
        data: report.toJson(),
        options: Options(responseType: ResponseType.plain),
      );

      // The per-server Dio sets `validateStatus: (_) => true` (`DioFactory`),
      // so this is the PRIMARY path, not a defensive one: every status
      // resolves here and the `on DioException` handler below sees only a
      // transport fault or an injected Dio's own rejection. An earlier
      // comment here had that backwards.
      //
      // A null status is not a fabricated 0: no server verdict exists, so it
      // classifies transient with no statusCode, same as the connection-level
      // path.
      final status = response.statusCode;
      if (status == null) {
        throw const FeedbackTransientSubmissionException(
          'Feedback endpoint returned no status',
        );
      }
      if (status < 200 || status >= 300) {
        throw _classifyStatus(
          status,
          'Feedback endpoint returned $status',
          cause: null,
        );
      }

      await _rejectUndecodableBody(response.data, status: status);
    } on FeedbackSubmissionException {
      rethrow;
    } on DioException catch (error) {
      throw _classifyDioException(error);
    } on Object catch (error) {
      // Contract breach territory (nothing else should escape Dio), so
      // stay conservative: transient keeps the user-approved report
      // queued and retriable instead of silently dropped.
      throw FeedbackTransientSubmissionException(
        'Feedback submission failed unexpectedly',
        cause: error,
      );
    }
  }

  /// Rejects a 2xx whose body is present and cannot be decoded.
  ///
  /// Reading the status is not enough to call a report delivered. A captive
  /// portal, SSO interstitial or WAF answers the POST with its own page and
  /// its own 200, and nothing about that response reached the application —
  /// so without this check `send` returns normally and the user is told a
  /// report was sent that was in fact discarded. Under `text/html` that was
  /// the behaviour before #358: no decode ran, the body resolved as a
  /// `String`, and the 2xx check passed.
  ///
  /// **This is a smell test, not proof of delivery**, and the name is meant
  /// to say so. An impostor that answers with well-formed JSON — a WAF's
  /// `{"error":"blocked"}`, an SPA catch-all's `{}` — passes it. Matching the
  /// API's own envelope would not fix that: #297 looked for exactly such a
  /// discriminator and rejected it, because the backend answers an unmatched
  /// route with the same envelope shape. What is catchable here is
  /// the common case — a page, not a payload.
  ///
  /// **Transient, not permanent**, and the distinction is the whole point.
  /// Permanent means `submit` surfaces the failure un-queued and
  /// `drainPending` drops the record — the user's own words, destroyed over a
  /// portal they will be off in a minute. This class already refuses that
  /// trade for `badCertificate` on the same reasoning. So the two-clause
  /// decode split #352 established (a non-JSON body is definitive; a failure
  /// to *perform* the decode is local) collapses to one bucket here, because
  /// neither clause licenses discarding the report. The messages stay
  /// distinct so a log still says which happened.
  ///
  /// Only a body that is present and unparseable disproves delivery. An empty
  /// or whitespace-only body does not: the wire contract is `→ 201` and this
  /// transport reads nothing out of the body, so demanding a shape would
  /// invent a contract the API never promised. Deliberately weaker than
  /// `HouseholdRemoteDataSourceImpl._requireJsonObject`, which needs the
  /// payload it is checking for.
  ///
  /// **That is an accepted gap, not an oversight**: a portal answering with
  /// `Content-Length: 0` and a 200 still reads as delivered. Closing it means
  /// requiring a body, which is only safe once the backend is known to send
  /// one on 201 — unverified here, and getting it wrong fails every genuine
  /// submission rather than a rare intercepted one. Tracked on #358.
  Future<void> _rejectUndecodableBody(
    String? body, {
    required int status,
  }) async {
    final text = body?.trim();
    // `trim()`, not `isEmpty`: a 201 whose body is a newline is a delivered
    // report, and `jsonDecode` throws `FormatException` on it just as it does
    // on a page. This gate is what lets success through, so it has to be the
    // generous form — unlike the same-looking check in the household remote,
    // where an empty body is already a failure.
    if (text == null || text.isEmpty) return;

    // A page announces itself in its first character, and JSON never begins
    // with `<`. Answering here keeps a multi-megabyte portal page out of
    // `jsonDecode` and, above `decodeJsonBody`'s 50 KB threshold, out of the
    // isolate hop it would otherwise pay to fail at character 1 — on a path
    // that runs while the app is reporting a crash.
    //
    // It is a fast path, NOT a replacement for the parse. A truncated genuine
    // response begins with `{`, and that is the other trigger this check
    // exists for, so a first-character test alone would stop detecting it.
    if (text.startsWith('<')) {
      throw FeedbackTransientSubmissionException(
        'Feedback endpoint answered $status with a page, not a payload, so '
        'the report did not reach the API',
        statusCode: status,
      );
    }

    try {
      await decodeJsonBody(text);
    } on FormatException catch (error) {
      throw FeedbackTransientSubmissionException(
        'Feedback endpoint answered $status with a body that is not JSON, so '
        'the report did not reach the API',
        cause: error,
        statusCode: status,
      );
    } on Object catch (error) {
      // Decoding could not be performed — in practice a failure to spawn the
      // offload isolate under resource pressure. Says nothing about the
      // response, and shares the bucket for the same reason.
      throw FeedbackTransientSubmissionException(
        'Feedback response could not be decoded',
        cause: error,
        statusCode: status,
      );
    }
  }

  /// Classifies [error] per the #97 table. A response status, when
  /// present, is authoritative; without one the failure is a
  /// connection-level fault and always transient.
  FeedbackSubmissionException _classifyDioException(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      return _classifyStatus(
        status,
        'Feedback submission failed with status $status',
        cause: error,
      );
    }
    // connectionTimeout / sendTimeout / receiveTimeout / connectionError /
    // cancel / badCertificate / unknown — no server verdict exists, so
    // the report stays retryable.
    return FeedbackTransientSubmissionException(
      'Feedback submission failed',
      cause: error,
    );
  }

  FeedbackSubmissionException _classifyStatus(
    int status,
    String message, {
    required Object? cause,
  }) {
    final transient = status >= 500 || _retryable4xx.contains(status);
    if (transient) {
      return FeedbackTransientSubmissionException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    if (status >= 400) {
      return FeedbackPermanentSubmissionException(
        message,
        cause: cause,
        statusCode: status,
      );
    }
    // A non-2xx, non-4xx/5xx status (1xx/3xx surfaced by a permissive
    // validateStatus) carries no rejection semantics — transient.
    return FeedbackTransientSubmissionException(
      message,
      cause: cause,
      statusCode: status,
    );
  }
}
