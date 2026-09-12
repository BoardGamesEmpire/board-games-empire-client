import 'package:dio/dio.dart';
import 'package:observability/observability.dart';

import '../network/decode_json_body.dart';

/// Concrete [FeedbackTransport] posting through a **per-server** Dio
/// instance (#69, #97).
///
/// Wire contract (backend `libs/api/feedback`): `POST /api/feedback/reports`
/// → **201** with `{ message, feedbackReport: { id, createdAt } }`; the
/// status is pinned by `@HttpCode(Http.Created)`, so 204 is unreachable and
/// every success carries that object (#363 **D1**).
///
/// The path is relative — the per-server Dio carries the base URL
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
///   discarding a user-approved report on one would be wrong), and — as
///   [FeedbackUnverifiedDeliveryException] — a 2xx that does not carry the
///   API's documented JSON object, which means something other than the API
///   answered (#358, #363 — see [_rejectUndecodableBody]).
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
      // another. `WellKnownClientImpl` pins for the same reason, and
      // additionally narrows the body at runtime — see the comment above
      // its `body is String` check for the routes a pin alone leaves open.
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

  /// Rejects a 2xx that does not carry the API's own success payload.
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
  /// to say so. An impostor that answers with a well-formed JSON object — a
  /// WAF's `{"error":"blocked"}`, an SPA catch-all's `{}` — passes it.
  /// Matching the API's own envelope would not fix that: #297 looked for
  /// exactly such a discriminator and rejected it, because the backend
  /// answers an unmatched route with the same envelope shape. What is
  /// catchable here is the common case — a page, or nothing at all, where a
  /// payload belongs.
  ///
  /// **Transient, not permanent**, and the distinction is the whole point.
  /// Permanent means `submit` surfaces the failure un-queued and
  /// `drainPending` drops the record — the user's own words, destroyed over a
  /// portal they will be off in a minute. This class already refuses that
  /// trade for `badCertificate` on the same reasoning. So neither clause of
  /// the two-clause decode split #352 established (a non-JSON body is
  /// definitive; a failure to *perform* the decode is local) licenses
  /// discarding the report.
  ///
  /// The two do **not** land in the same bucket, though — which they did
  /// until #359 gave "transient" a second axis. A body this client read and
  /// could not recognise is a statement about *this response*: it counts an
  /// attempt and the drain moves on to the next record
  /// ([FeedbackUnverifiedDeliveryException]). A failure to *perform* the
  /// decode — no isolate available under memory pressure — is a statement
  /// about the *device*, and every record behind it would fail the same
  /// way, so it stays the plain [FeedbackTransientSubmissionException] and
  /// the drain stops without counting anything. The messages stay distinct
  /// so a log still says which happened.
  ///
  /// That is a deliberate divergence from `decodeJsonBody`'s own doc, which
  /// tells callers to treat a `FormatException` as permanent. The advice fits
  /// a caller deprived of a payload it needed; this transport needs nothing
  /// out of the body, and permanent here means deleting the user's words.
  /// Classification belongs to the caller, not the parser.
  ///
  /// An unparseable body does not prove non-delivery either — it *withdraws*
  /// the delivery claim rather than settling it the other way. A truncated
  /// genuine response is unparseable and did arrive, and a body starting with
  /// `<` is a page a proxy could equally have substituted for a real answer
  /// on the way back. That asymmetry is a third reason the bucket is
  /// transient, and the exception messages say what was observed rather than
  /// what it proves.
  ///
  /// ## Why an empty body is rejected too (#363 **D1**, **D2**)
  ///
  /// It was not, until the backend was read. The wire contract is stated
  /// positively now rather than inferred: `POST /api/feedback/reports`
  /// answers **201** with `{ message, feedbackReport: { id, createdAt } }` —
  /// `feedback.controller.ts:19-24` declares the envelope and `:70-73`
  /// builds it — on a fresh submission and on an idempotent replay alike.
  /// **204 is unreachable**, because `@HttpCode(Http.Created)` pins the
  /// status (`:58-59`) and the handler emits exactly one value. The only
  /// global response interceptor rewrites i18n markers in place and returns
  /// marker-free bodies by reference, so it cannot empty one.
  ///
  /// So a 2xx carrying no body, or a whitespace-only body, is not this API
  /// answering, and the empty-body exemption that used to let it through was
  /// closing a gap the contract never asked for. Requiring a JSON **object**
  /// rather than merely a non-empty body costs nothing in false rejections
  /// for the same reason, and additionally catches an impostor answering
  /// `[]`, `"ok"` or `123`.
  ///
  /// Still deliberately weaker than
  /// `HouseholdRemoteDataSourceImpl._requireJsonObject`: that caller needs
  /// the payload it is checking for, and this one reads nothing out of it.
  /// The object requirement asserts the documented shape, and stops there —
  /// no key is required, per #297's finding above.
  Future<void> _rejectUndecodableBody(
    String? body, {
    required int status,
  }) async {
    final text = body?.trim();
    // `trim()` folds whitespace in with empty deliberately: a 2xx whose body
    // is a newline carries no more of a receipt than one with no body at all,
    // and the contract says every genuine success carries the receipt.
    if (text == null || text.isEmpty) {
      throw FeedbackUnverifiedDeliveryException(
        'Feedback endpoint answered $status with an empty body; the API '
        'answers 201 with a report receipt, so delivery could not be '
        'confirmed',
        statusCode: status,
      );
    }

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
      throw FeedbackUnverifiedDeliveryException(
        'Feedback endpoint answered $status with a page, not a payload; '
        'delivery could not be confirmed',
        statusCode: status,
      );
    }

    final Object? decoded;
    try {
      decoded = await decodeJsonBody(text);
    } on FormatException catch (error) {
      throw FeedbackUnverifiedDeliveryException(
        'Feedback endpoint answered $status with a body that is not JSON; '
        'delivery could not be confirmed',
        cause: error,
        statusCode: status,
      );
    } on Object catch (error) {
      // Decoding could not be performed — in practice a failure to spawn the
      // offload isolate under resource pressure. Deliberately the run-level
      // transient and NOT the unverified-delivery subtype: this says nothing
      // about the response, it says the device is out of room, and every
      // record behind this one in the same drain would fail identically.
      // The subtype counts an attempt and continues, so routing it here
      // would let one moment of memory pressure charge the entire queue
      // (#359 **D4**).
      throw FeedbackTransientSubmissionException(
        'Feedback response could not be decoded',
        cause: error,
        statusCode: status,
      );
    }

    // Valid JSON that is not an object: `[]`, `"ok"`, `123`, `null`. The
    // documented success payload is an object, so none of these is the API.
    if (decoded is! Map<String, dynamic>) {
      throw FeedbackUnverifiedDeliveryException(
        'Feedback endpoint answered $status with JSON that is not an object; '
        'delivery could not be confirmed',
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
