import 'package:http_status/http_status.dart';

/// What a session endpoint's status says about the session (#98, #180).
enum SessionReadStatus {
  /// 401 or 403: the server disowned the session.
  noSession,

  /// 200: read the body. An empty body or a JSON `null` is the third
  /// no-session answer, decided after the decode.
  readBody,

  /// Anything else, a null status included: says nothing about the session.
  /// The caller throws: `AuthServerException` for a resolved response, its
  /// own mapping of the `DioException` for a thrown one.
  undecided,
}

/// Classifies a session read by its [status] alone.
///
/// Both auth repositories' `getSession` ask this on both of their paths, the
/// resolved `Response` and the thrown `DioException`, so which statuses
/// settle a session holds on native and web by construction rather than by a
/// comment asking each to keep pace with the other (#278).
///
/// What each does with the answer stays local. On
/// [SessionReadStatus.noSession] native clears the stored token, and web,
/// which has only the browser's cookie, settles on unauthenticated. The throw
/// for [SessionReadStatus.undecided] is the caller's too, because the two
/// paths need different ones: a resolved response with no session answer is
/// a server fault, while a thrown request with no status was never answered
/// at all, which `_mapDioException` reports as a network failure.
///
/// - **401 and 403 are [SessionReadStatus.noSession], resolved or thrown.**
///   A thrown one comes from an injected `Dio` whose `validateStatus` is not
///   the factory's, or from an interceptor, and is the same answer. Leaving a
///   403 undecided would strand a genuinely revoked session on the
///   retry-forever view with no way out. A false positive from an
///   intermediary costs one re-sign-in, which is the cheaper failure (#180).
/// - **Every other status is [SessionReadStatus.undecided], and the caller
///   must throw, not return null** (#98). A null made a 5xx during startup
///   restore indistinguishable from "no session", so a transient server fault
///   sent the user to the sign-in form and implied their stored session had
///   been rejected. A 2xx that is not the documented 200, a 3xx, and a
///   response with no status at all carry neither a session nor a rejection,
///   so they land here too.
/// - **Switch on this before inspecting the body.** An earlier
///   `response.data == null` test that ignored the status turned a bodiless
///   502, a proxy fault, into a definitive "no session" (#180).
/// - **The third no-session shape waits for the decode.** BetterAuth answers
///   an absent or expired session with a 200 and no payload, which is
///   [SessionReadStatus.readBody] here. Only the decoded body can say so:
///   reading "no session" off an undecoded string would call a captive
///   portal's HTML page a rejected session (#352).
SessionReadStatus readSessionStatus(int? status) => switch (status) {
  HttpStatusCode.unauthorized ||
  HttpStatusCode.forbidden => SessionReadStatus.noSession,
  HttpStatusCode.ok => SessionReadStatus.readBody,
  _ => SessionReadStatus.undecided,
};
