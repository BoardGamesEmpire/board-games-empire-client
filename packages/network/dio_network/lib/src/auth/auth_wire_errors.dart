import 'package:dio/dio.dart';
import 'package:dio_network/src/auth/rate_limited.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:http_status/http_status.dart';
import 'package:interfaces/repositories.dart';

// How an auth response or a thrown DioException maps to an [AuthException],
// shared by the native `AuthRepositoryImpl` and the web
// `WebAuthRepositoryImpl` (#877). Both drive the same Dio against the same
// server, and a rule that held on one platform only is how #352 arose.
//
// None of this reads repository state. Each repository keeps what differs on
// purpose: its grant handling, and its own `_plainBody` (#360).

/// Whether [status] is a 2xx.
///
/// Used by [assertAuthSuccess] and by the web repository's sign-out, grant
/// and provider-start checks. Those had the range test written out
/// separately, so a change to what counts as success — treating 3xx as its
/// own case, say — could have landed on one and missed the other, leaving
/// sign-out logging "not accepted" for a status sign-in treats as fine. The
/// native repository's own grant checks still write the range out.
///
/// A null status means Dio resolved a response without one, which is not a
/// success an auth repository will act on.
bool isAuthSuccessStatus(int? status) =>
    status != null &&
    status >= HttpStatusCode.ok &&
    status < HttpStatusCode.multipleChoices;

/// Decodes a body the transport was told not to touch, **deferring** the
/// failure so the status can speak first.
///
/// Every auth request asks Dio for `Response<String>` **and pins
/// `responseType` per request** — together, not either alone.
/// `DioMixin.fetch` forces `responseType` from `T`, so `String` gives
/// `plain` and anything else gives `json`
/// (`dio-5.11.0/lib/src/dio_mixin.dart:419-427`) — but it skips that forcing
/// entirely for an instance already set to `bytes` or `stream` (`:419-421`),
/// and both auth repositories take an arbitrary `Dio` by constructor. The pin
/// is what makes the rule true there rather than only for the Dio the
/// factories build (see each repository's `_plainBody`, #360). Either half of
/// Dio's own handling — the cast, or a `jsonDecode` driven by a content type
/// that merely *claims* JSON — throws from inside the call as
/// `DioException(type: unknown)` with **no response attached**. The status
/// was gone before anything could classify it, so every such answer became
/// `AuthNetworkException`: the INDETERMINATE bucket, which keeps a dead
/// session on the retry-forever view with no way out (#352).
///
/// The failure is **returned, not thrown**, because the callers disagree
/// about what it means. A rejected response whose body will not parse is
/// still a rejection and its status is the honest answer — the
/// duplicate-email probe simply finds no envelope there. Only a 2xx has to
/// answer for an unreadable body.
///
/// Which failure it was decides the bucket, and that distinction matters
/// more here than anywhere else in the client. A body that is not JSON is a
/// statement *about the response* and is definitive. A failure to **perform**
/// the decode — an isolate that would not spawn — is local and momentary and
/// must stay retryable: filing it as definitive would clear the user's
/// credentials over a fault the server had no part in.
///
/// [decode] is the calling repository's own injected JSON decode: always
/// `decodeJsonBody` in production, and a test seam for the isolate failure no
/// response body can produce (#364). [context] names the operation in a
/// failure's message, and [status] is the status the body arrived with.
Future<({Object? value, AuthException? failure})> decodeAuthBody(
  String? raw, {
  required Future<Object?> Function(String) decode,
  required String context,
  required int? status,
}) async {
  if (raw == null || raw.isEmpty) return (value: null, failure: null);

  try {
    return (value: await decode(raw), failure: null);
  } on FormatException catch (error) {
    return (
      value: null,
      failure: AuthServerException(
        message:
            'The server returned a body that is not JSON during '
            '$context.',
        statusCode: status,
        cause: error,
      ),
    );
  } on Object catch (error) {
    return (
      value: null,
      failure: AuthLocalDecodeException(
        message: 'This device could not decode the response during $context.',
        cause: error,
      ),
    );
  }
}

/// Throws the [AuthException] a credential grant's resolved response means,
/// or returns for a 2xx that carries no rejection.
///
/// [body] is the raw text for a rejection, read under [probeJsonBody]'s
/// bound, or the body a repository has already decoded for a 2xx. The
/// duplicate-email envelope is not status-gated, so a 2xx can carry it too.
/// [headers] supply a 429's wait, and [context] names the operation in a
/// server fault's message.
void assertAuthSuccess(
  int? status,
  Object? body, {
  required Headers? headers,
  required String context,
}) {
  if (status == HttpStatusCode.unauthorized) {
    throw const AuthInvalidCredentialsException();
  }

  if (status == HttpStatusCode.forbidden) throw forbiddenRefusal(body);

  // A 429 is a rate limit whatever its body says (#559): classified on the
  // status alone, with the wait read from `X-Retry-After` when it is there.
  // It sits before the duplicate-email check, which reads a body code at any
  // status, and before the generic non-2xx throw, which would file it as a
  // server fault with nothing to act on.
  if (status == HttpStatusCode.tooManyRequests) {
    throw rateLimitedFrom(headers);
  }

  if (isEmailAlreadyExists(status, body)) {
    throw const AuthEmailAlreadyExistsException();
  }

  if (!isAuthSuccessStatus(status)) {
    throw AuthServerException(
      message: 'Unexpected $status during $context.',
      statusCode: status,
    );
  }
}

/// Whether a rejected auth response means "this email is already
/// registered".
///
/// BetterAuth signals a duplicate sign-up as **422 Unprocessable Entity**
/// with a `USER_ALREADY_EXISTS*` body code — it never uses 409. The exact
/// code varies by version (`USER_ALREADY_EXISTS` per the docs;
/// `USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL` observed live on the BGE dev
/// server), so match the stable prefix rather than one literal. The 409
/// Conflict mapping is kept for BGE's own route conventions. Deliberately
/// NOT a bare status-422 match: other validation failures could share the
/// status, and showing "account already exists" for those would be worse
/// than the generic server-error copy.
bool isEmailAlreadyExists(int? status, Object? body) {
  if (status == HttpStatusCode.conflict) return true;
  final code = authRejectionCode(body);
  return code != null && code.startsWith('USER_ALREADY_EXISTS');
}

/// What a 403 on a credential grant means, read by its body code (#394).
///
/// BetterAuth answers two refusals with a 403 that are not a wrong
/// password: `EMAIL_NOT_VERIFIED` on sign-in, after the password check has
/// passed, and `REGISTRATION_DISABLED` from the `/sign-up/email` route gate
/// once the server has closed registration (#443). Each code comes from one
/// route only, so the code decides, not which grant made the request.
///
/// The code is read under the same bound as the duplicate-email envelope.
/// The status still decides first: only a 403 gets here, and the body only
/// refines it. A 403 without a readable envelope (a proxy's HTML page, an
/// envelope past [probeJsonMaxChars], no body at all) stays the invalid
/// credentials it always was.
AuthException forbiddenRefusal(Object? body) =>
    switch (authRejectionCode(body)) {
      'EMAIL_NOT_VERIFIED' => const AuthEmailNotVerifiedException(),
      'REGISTRATION_DISABLED' => const AuthRegistrationDisabledException(),
      _ => const AuthInvalidCredentialsException(),
    };

/// The `code` of a rejection envelope, or null when [body] is not one.
///
/// [body] is the raw text, or a body a repository's grant check has already
/// decoded; both go through [probeJsonBody]. [mapAuthDioException] reads the
/// raw text off a **thrown** `DioException` too: without the probe, a
/// duplicate sign-up rejected by a `Dio` whose `validateStatus` is not its
/// platform factory's (`DefaultDioFactory` on native, `WebDioFactory` on the
/// web) would report "unexpected 422" instead of "that account already
/// exists".
///
/// It probes rather than decodes because a rejection envelope is small, and
/// `decodeJsonBody`'s isolate hop would make this async for nothing.
String? authRejectionCode(Object? body) {
  final decoded = probeJsonBody(body);
  final code = decoded is Map ? decoded['code'] : null;
  return code is String ? code : null;
}

/// Maps a thrown [DioException] from an auth request to the domain
/// exception the auth bloc categorises.
///
/// [credentialGrant] gates the body probes, the duplicate-email one and a
/// 403's code, which are meaningful only where an account is being created
/// or a credential presented.
///
/// [isEmailAlreadyExists] treats **any** 409 as a duplicate, so without
/// this a 409 from the session endpoint — a route that cannot mean
/// "that email is taken" — reached the caller as
/// `AuthEmailAlreadyExistsException` instead of the server fault it is.
/// The response path never had the bug: it classifies a 409 by status
/// before any envelope is consulted. Only the thrown path, reachable with
/// an injected `Dio` whose `validateStatus` is not its platform factory's,
/// routed a session 409 through the grant vocabulary.
AuthException mapAuthDioException(
  DioException e, {
  required bool credentialGrant,
}) {
  // The wire-level failure itself is logged by NetworkLogInterceptor
  // (redacted URI + dio_error_type + status); here we only map it to the
  // domain exception the bloc will categorise (#100 layering).
  final status = e.response?.statusCode;
  if (status == HttpStatusCode.unauthorized) {
    return const AuthInvalidCredentialsException();
  }

  // `getSession` settles a session 403 before it gets here, whatever its
  // body says, so only a grant's body is read.
  if (status == HttpStatusCode.forbidden) {
    return credentialGrant
        ? forbiddenRefusal(e.response?.data)
        : const AuthInvalidCredentialsException();
  }

  // Only a credential grant's 429 is a rate-limited grant (#559); a session
  // read that is throttled stays what it was. Ahead of the duplicate-email
  // check, as in [assertAuthSuccess].
  if (credentialGrant && status == HttpStatusCode.tooManyRequests) {
    return rateLimitedFrom(e.response?.headers);
  }

  if (credentialGrant && isEmailAlreadyExists(status, e.response?.data)) {
    return const AuthEmailAlreadyExistsException();
  }

  if (status != null && status >= HttpStatusCode.internalServerError) {
    return AuthServerException(
      message: 'Server error $status.',
      statusCode: status,
      cause: e,
    );
  }

  // Genuine transport: the request was never answered, so there is no
  // status to classify by and INDETERMINATE is the honest bucket.
  // `sendTimeout` joins the list it was missing from — it fell to the
  // catch-all below, which used to reach the same answer by accident and
  // no longer does.
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.connectionError) {
    return AuthNetworkException(
      message: 'Connection failed. Check your network.',
      cause: e,
    );
  }

  // The server answered, with something the branches above did not claim —
  // a 404 from a misrouted path, a 400 or 422 it rejected. That is a server
  // fault, and calling it a network one ("Connection failed. Check your
  // network.") told the user to check the one part of the system
  // demonstrably working (#283). Reachable because each auth repository
  // accepts any injected `Dio`: the platform factories' permissive
  // `validateStatus` resolves these as responses, but an interceptor or a
  // differently configured Dio throws them.
  if (status != null) {
    return AuthServerException(
      message: 'Unexpected $status from the server.',
      statusCode: status,
      cause: e,
    );
  }

  // No status and no transport type: a cancellation, a bad certificate, or
  // a fault Dio could not attribute. Nothing answered, so INDETERMINATE.
  return AuthNetworkException(
    message: e.message ?? 'Network error.',
    cause: e,
  );
}
