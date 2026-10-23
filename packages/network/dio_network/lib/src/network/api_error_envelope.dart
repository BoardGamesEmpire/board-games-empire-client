import 'dart:convert';

/// Whether [body] is the API's own error envelope for [status].
///
/// Nest renders every `HttpException` carrying a message as
/// `{ statusCode, message, error }` — `HttpException.createBody`, re-issued by
/// the backend's `I18nExceptionFilter` after it resolves the translation key.
/// A gateway, proxy or WAF answering for the API does not produce that shape,
/// so the envelope is evidence that **the application itself wrote this
/// response**.
///
/// It is evidence and not proof, and what it can settle differs by status:
///
/// - At **404** it settles nothing on a fixed route, because Nest answers an
///   unmatched route with a 404 carrying this same envelope (`Cannot POST
///   /api/households`). That is why #297 rejected it there.
/// - At **403** it does separate the cases, because Nest does not answer an
///   unmatched route with a 403 — so an envelope-free 403 was written by
///   something in front of the API (#350, #365).
/// - At a 404 that a call site can read as a statement about a **row**, it is
///   the minimum bar before drawing that conclusion (#253).
///
/// [body] is accepted as `Object?` because it arrives in two shapes. Data
/// sources that ask Dio for `Response<String>` hold the raw text; a body that
/// reached here already decoded is passed through as-is. Only the raw-text
/// path is bounded — a body that is already a map cost nothing to inspect.
bool isApiErrorEnvelope(Object? body, int status) {
  final decoded = body is String ? _probeJson(body) : body;
  return decoded is Map &&
      decoded['statusCode'] == status &&
      decoded['message'] != null &&
      decoded['error'] is String;
}

/// Whether [body] says the request that drew it can be sent again unchanged:
/// a `retryable: true` field beside the error.
///
/// The backend sets it on the 409 it renders for a deadlock that outlived the
/// call site's own retry (backend #398). Two writers wanted the same rows and
/// Postgres aborted one; nothing about the request was wrong, so the same
/// request is expected to succeed (#431). The field is read, never the
/// message, which is translated per request locale.
///
/// [body] arrives in the same two shapes [isApiErrorEnvelope] accepts and goes
/// through the same bounded probe, for the same reason: the body is about to
/// be discarded on its status.
bool isRetryableRefusal(Object? body) {
  final decoded = body is String ? _probeJson(body) : body;
  return decoded is Map && decoded['retryable'] == true;
}

/// The string [field] of an error body, or null when the body has none.
///
/// For the fields a refusal carries beside the envelope, such as a 402's
/// `resource` and `scope` (#455). Same bounded probe as [isApiErrorEnvelope].
String? apiErrorField(Object? body, String field) {
  final decoded = body is String ? _probeJson(body) : body;
  if (decoded is! Map) return null;
  final value = decoded[field];
  return value is String ? value : null;
}

/// Ceiling on the synchronous probe below.
///
/// An error envelope is a few hundred bytes — Nest's is about a hundred — so
/// anything past this is not the envelope being looked for, and reading it
/// would be paying main-isolate parse time for a body that cannot answer the
/// question. Matches `AuthRepositoryImpl._probeMaxChars`, which bounds the
/// same kind of probe for the same reason.
const int _probeMaxChars = 4 * 1024;

/// Best-effort synchronous decode, for envelope probes alone.
///
/// Deliberately **not** routed through `decodeJsonBody`: this reads a rejection
/// envelope, which is small, on a body that is about to be discarded on its
/// status. Paying `decodeJsonBody`'s isolate hop to answer a yes/no question
/// about a body's first few keys is the cost `AuthRepositoryImpl._probeJson`
/// already refuses on the same question. Staying synchronous also keeps the
/// classifier free of an `await`.
///
/// **Bounded, because it runs synchronously on the UI isolate.** Taking the
/// body as a `String` drops dio's `FusedTransformer`, which would otherwise
/// offload a decode above 50 KB; a length bound is the only way a synchronous
/// probe can restore that protection. Without it a multi-megabyte captive
/// portal page would be parsed in full, on the frame it lands on, to discover
/// it is not an envelope — the exact cost this function exists to avoid.
///
/// A body that will not parse, or is too large to be the envelope, simply is
/// not it — so both return null rather than throwing. Callers must not read
/// that as a statement about the response beyond "this is not the API's error
/// envelope".
Object? _probeJson(String text) {
  if (text.isEmpty || text.length > _probeMaxChars) return null;
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
