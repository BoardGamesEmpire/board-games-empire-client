/// One reading of a failed remote request, for every per-server remote
/// source (#260).
///
/// Each source keeps its own exception family, because its interface and its
/// callers match on those types. What it hands this file is a
/// [RemoteFailureFamily], a small adapter that builds them. The reading
/// itself is written once, here: [remoteVerdictFor] for a status,
/// [failureForStatus] and [failureForDioException] for a failure, and
/// [sendForJson] and [parseRemote] around a request.
///
/// ## The question
///
/// The question is never "did this fail" — the status already says so — but
/// **"will the same request fail the same way again?"**, because that is
/// what a caller acts on. Permanent ends the retrying: the sync drain parks
/// the entry until someone retries or discards it by hand (#121), and the
/// feedback drain drops the report. Transient keeps either queued. So where
/// something in front of the API commonly answers — a 403 or a 404 — the
/// classifier wants evidence that the API itself rejected the request, not
/// merely that something rejected it, before it gives up.
///
/// - **5xx** — transient.
/// - **401, 407, 408, 429** — transient, though they are 4xx. An expired
///   session, proxy authentication, a request timeout and the throttle are
///   all conditions a later attempt can survive. 407 is here because no API
///   route emits it: it is defined to come from a proxy, so it says the
///   request never reached the application (#350). 511 belongs with it and
///   needs no entry: as a 5xx, it is already transient.
/// - **403 and 404 without the API's error envelope** — transient. Something
///   in front of the API answered.
/// - **409 saying `retryable: true`** — transient. It is the backend's answer
///   to a deadlock that outlived its own retry: a concurrency accident on the
///   server, not a judgement on the request (#431).
/// - **Any other 4xx** — [RemoteVerdict.refused], for the source's
///   [RemoteFailureFamily.refused] to read. Unclaimed, it is permanent: a
///   400, any other 409, or a 422 is read as the application rejecting the
///   request's content, and the content will not change on retry. The
///   exception is an enveloped 404, which stays transient (#297). A 400 is
///   permanent with or without the envelope: unlike a 403, a 400 without it
///   is not evidence that a proxy answered, and transient would retry, on
///   every pass, a refusal nothing says will change. A source whose routes
///   give it a reason to read a 400's envelope does so in its hook, as the
///   DataGateway source does.
/// - **1xx / 3xx** — transient. Surfaced only by the permissive
///   `validateStatus`, and carrying no rejection semantics at all.
///
/// ## The envelope at 403 and 404
///
/// What the envelope can settle at each status is in [isApiErrorEnvelope]'s
/// doc (#297, #350, #365). Nest never answers an unmatched route with a 403,
/// so a 403 without the envelope was written by something in front of the
/// API: a proxy or a WAF. It does answer one with an enveloped 404, so on a
/// fixed or list route even an enveloped 404 may be a partial deploy.
/// Permanent there would end a hydrate, or park a queued create, over a
/// failure a retry thirty seconds later would have survived. Only a source's
/// own [RemoteFailureFamily.refused] hook, on a request that names a row, may
/// read an enveloped 404 as that row being gone.
///
/// The 403 rule rests on every production 403 being raised with a message,
/// so that Nest renders the envelope. A bare `ForbiddenException()` added to
/// a route later would read as a proxy block, and retry a refusal that will
/// never change. Nothing in this package can notice that happen; #263 is the
/// mechanism that would.
///
/// The cost of getting a 403 wrong runs one way. A wrong permanent gives up
/// over a block a retry after leaving the network would have survived: the
/// sync drain parks the entry for someone to retry by hand (#121), and the
/// feedback drain drops the report. A genuine refusal misread as transient is
/// only retried, at most once per drain pass (#350).
library;

import 'package:dio/dio.dart';

import 'api_error_envelope.dart';
import 'decode_json_body.dart';

/// What an answered request that did not succeed says (#260).
enum RemoteVerdict {
  /// A status below 400 that no other verdict claims: a 1xx/3xx, or a 2xx
  /// that arrived inside a [DioException].
  noAnswer,

  /// 401.
  sessionRejected,

  /// 408 or 429.
  throttled,

  /// 407, or a 403/404 without the API's error envelope.
  notTheApi,

  /// 5xx.
  serverError,

  /// 409 with `retryable: true` (#431).
  retryableConflict,

  /// Any other 4xx: the source decides; see [RemoteFailureFamily.refused].
  refused;

  /// Whether the shared rules alone make it transient: every verdict but
  /// [refused], which [failureForStatus] hands to the source's hook and then
  /// to its 404 or permanent default.
  bool get isTransient => this != refused;
}

/// The [RemoteVerdict] for an answered request's non-2xx [status].
///
/// [body] is the raw, undecoded body when there is one. Only a 403, 404 or
/// 409 reads it, and only through the bounded probes in
/// `api_error_envelope.dart`.
RemoteVerdict remoteVerdictFor(int status, {required Object? body}) =>
    switch (status) {
      >= 500 => RemoteVerdict.serverError,
      401 => RemoteVerdict.sessionRejected,
      408 || 429 => RemoteVerdict.throttled,
      407 => RemoteVerdict.notTheApi,
      409 when isRetryableRefusal(body) => RemoteVerdict.retryableConflict,
      (403 || 404) when !isApiErrorEnvelope(body, status) =>
        RemoteVerdict.notTheApi,
      >= 400 => RemoteVerdict.refused,
      _ => RemoteVerdict.noAnswer,
    };

/// A [RemoteVerdict.refused] answer, as a source's
/// [RemoteFailureFamily.refused] reads it.
final class RemoteRefusal {
  const RemoteRefusal({
    required this.status,
    required this.fromApi,
    required this.body,
    required this.message,
    required this.cause,
  });

  /// The 4xx the request was answered with.
  final int status;

  /// Whether [body] is the API's own error envelope for [status], by
  /// [isApiErrorEnvelope]: the least a source needs before it reads the
  /// refusal as a statement about the caller or a row.
  ///
  /// Always true at 403 and 404: without the envelope those are
  /// [RemoteVerdict.notTheApi], and never reach a hook. A hook checks it only
  /// at the statuses the shared rules do not read the envelope for.
  final bool fromApi;

  /// The raw, undecoded body, for a field read with `apiErrorField`.
  final Object? body;

  /// The diagnostic the failure carries.
  final String message;

  /// The [DioException] the answer arrived in, or null when the response was
  /// returned rather than thrown.
  final Object? cause;
}

/// How one source builds its own exceptions from the shared reading.
///
/// [transient] and [permanent] build the two halves every family has, and
/// are usually its two exceptions' constructors, torn off:
///
/// ```dart
/// const failures = RemoteFailureFamily<UserRemoteException>(
///   transient: UserRemoteTransientException.new,
///   permanent: UserRemotePermanentException.new,
/// );
/// ```
///
/// A source that reads nothing beyond the shared rules uses an instance like
/// that one. A source with a reading of its own subclasses, passes the same
/// two tear-offs to `super`, and overrides a hook: [refused] or
/// [unanswered]. Each hook returns null to take the default. So what a
/// subclass declares is exactly what is special about its source.
class RemoteFailureFamily<E extends Object> {
  const RemoteFailureFamily({required this.transient, required this.permanent});

  /// Builds a failure a later attempt at the same request can survive.
  /// `statusCode` is null when nothing answered.
  final E Function(String message, {int? statusCode, Object? cause}) transient;

  /// Builds a failure the same request will meet again.
  final E Function(String message, {required int statusCode, Object? cause})
  permanent;

  /// The source's own reading of a [RemoteVerdict.refused] answer, or null
  /// for the default.
  ///
  /// The default is [permanent], except at 404, where it is [transient] (see
  /// the library doc). A source whose request names a row may claim an
  /// enveloped 404 as that row being gone.
  E? refused(RemoteRefusal refusal) => null;

  /// The source's own reading of a failure with no response, or null for
  /// [transient].
  E? unanswered(DioException error, String message) => null;
}

/// [family]'s failure for an answered request's non-2xx [status].
///
/// [message] is the diagnostic, which a transient verdict that needs
/// explaining extends. [body] is the raw, undecoded body when there is one.
/// [cause] is the [DioException] the answer arrived in, if it arrived in one.
E failureForStatus<E extends Object>(
  RemoteFailureFamily<E> family,
  int status,
  String message, {
  required Object? body,
  required Object? cause,
}) {
  final verdict = remoteVerdictFor(status, body: body);
  if (verdict.isTransient) {
    final why = switch (verdict) {
      RemoteVerdict.notTheApi when status == 403 || status == 404 =>
        '; the request did not reach the API',
      RemoteVerdict.retryableConflict =>
        '; the server hit a deadlock and asked for a retry',
      _ => '',
    };
    return family.transient('$message$why', statusCode: status, cause: cause);
  }

  final refusal = RemoteRefusal(
    status: status,
    fromApi: isApiErrorEnvelope(body, status),
    body: body,
    message: message,
    cause: cause,
  );
  if (family.refused(refusal) case final claimed?) return claimed;
  if (status == 404) {
    // Enveloped, but Nest's route-not-found is enveloped too, so nothing says
    // the API refused the request rather than missed it (#297).
    return family.transient(
      '$message; the route was not reachable',
      statusCode: status,
      cause: cause,
    );
  }
  return family.permanent(message, statusCode: status, cause: cause);
}

/// [family]'s failure for a [DioException] a request threw.
///
/// A response, when the exception carries one, is authoritative: an injected
/// Dio with a strict `validateStatus` throws for a non-2xx, and its status and
/// body are read as if they had been returned. Without one the failure is a
/// connection-level fault, transient unless the source's
/// [RemoteFailureFamily.unanswered] says otherwise.
E failureForDioException<E extends Object>(
  RemoteFailureFamily<E> family,
  DioException error, {
  required String action,
}) {
  final status = error.response?.statusCode;
  if (status != null) {
    return failureForStatus(
      family,
      status,
      '$action failed with status $status',
      body: error.response?.data,
      cause: error,
    );
  }
  final message = '$action failed';
  return family.unanswered(error, message) ??
      family.transient(message, cause: error);
}

/// A 2xx answer's body, decoded, and the status it came with.
typedef RemoteJson = ({Map<String, dynamic> body, int status});

/// Sends [request] and returns its 2xx body as a JSON object with the status
/// it came with, having turned every failure into one of [family]'s: no
/// response, a status outside 2xx, and a body that is not a JSON object.
///
/// [request] must ask for `Response<String>` with the response type pinned,
/// which keeps Dio out of the body; see [decodeJsonBody] for how Dio's own
/// handling would lose the status, and a source's `_plainBody` for why the pin
/// is per request. The body is decoded here, once the status is known. A 2xx
/// whose body is empty, not JSON or not an object is permanent, and keeps its
/// 2xx status. Realistic triggers: a captive portal or SPA catch-all serving
/// HTML — under `text/html` **or** `application/json`, since content type is
/// not a promise about content — and a dropped connection truncating a
/// genuine JSON body.
///
/// One decode failure stays transient: [decodeJsonBody] hands a large body to
/// another isolate, and a failure to spawn one is a local, momentary
/// condition, not a statement about the response. Permanent would tell the
/// caller a retry cannot succeed, so it would give up over a fault the server
/// had no part in (#297).
///
/// Nothing raw leaves. A non-Dio throw from [request], such as a `TypeError`
/// from an interceptor, is transient with no status. So a caller checks its
/// arguments before calling this, never inside [request], where an
/// `ArgumentError` would be wrapped.
///
/// With [readBody] false the body is not read, and the result's is empty: for
/// a route whose 2xx carries nothing the caller needs.
Future<RemoteJson> sendForJson<E extends Object>(
  Future<Response<String>> Function() request, {
  required String action,
  required RemoteFailureFamily<E> family,
  bool readBody = true,
}) async {
  final Response<String> response;
  try {
    response = await request();
  } on DioException catch (error) {
    throw failureForDioException(family, error, action: action);
  } on Object catch (error) {
    // `Object`, not `Exception`, so an `Error` cannot leave raw either.
    throw family.transient('$action failed unexpectedly', cause: error);
  }

  final status = response.statusCode;
  if (status == null) {
    throw family.transient('$action returned no status');
  }
  if (status < 200 || status >= 300) {
    throw failureForStatus(
      family,
      status,
      '$action returned $status',
      body: response.data,
      cause: null,
    );
  }
  if (!readBody) return (body: const <String, dynamic>{}, status: status);

  final raw = response.data;
  if (raw == null || raw.isEmpty) {
    throw family.permanent(
      '$action returned an empty body',
      statusCode: status,
    );
  }

  final Object? decoded;
  try {
    decoded = await decodeJsonBody(raw);
  } on FormatException catch (error) {
    throw family.permanent(
      '$action returned a body that is not JSON',
      statusCode: status,
      cause: error,
    );
  } on Object catch (error) {
    // An isolate that would not spawn, as the doc above says. This sits
    // outside the net around `request`, so without this clause it would leave
    // raw.
    throw family.transient(
      '$action could not be decoded',
      statusCode: status,
      cause: error,
    );
  }

  if (decoded is! Map<String, dynamic>) {
    throw family.permanent(
      '$action returned a body that is not a JSON object',
      statusCode: status,
    );
  }
  return (body: decoded, status: status);
}

/// Runs [map] over a 2xx body, and turns anything it throws into [family]'s
/// permanent failure with the 2xx [status]: the same request returns the same
/// body, so one that cannot be mapped now never will be.
T parseRemote<E extends Object, T>(
  RemoteFailureFamily<E> family,
  T Function() map, {
  required String action,
  required int status,
}) {
  try {
    return map();
  } on Object catch (error) {
    throw family.permanent(
      'Failed to parse the $action response: $error',
      statusCode: status,
      cause: error,
    );
  }
}
