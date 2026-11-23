import 'package:dio/dio.dart';
import 'package:dio_network/src/auth/auth_wire_errors.dart';
import 'package:dio_network/src/auth/session_read_status.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/dto.dart';

// The part of a resolved session read the native `AuthRepositoryImpl` and the
// web `WebAuthRepositoryImpl` share (#878). Each repository keeps what it
// does around it: its `DioException` catch, what "superseded" means for it,
// its log lines, its reaction to no session, and everything after a found
// one (native's store and post-store recheck, web's dropped token).

/// Which supersession check fired.
enum SessionReadCheckpoint {
  /// As the response resolved, before its status was read.
  response,

  /// After the body's decode, a suspension point, and before anything the
  /// decode found was acted on.
  decode,
}

/// What [readSessionResponse] found.
sealed class SessionRead {
  const SessionRead();
}

/// Something newer than the read happened while it was in flight. The
/// caller discards the response without touching storage or state.
final class SessionReadSuperseded extends SessionRead {
  const SessionReadSuperseded(this.checkpoint);

  final SessionReadCheckpoint checkpoint;
}

/// The server said there is no session: a 401 or 403, or a 200 with no
/// session payload.
final class SessionReadNoSession extends SessionRead {
  const SessionReadNoSession(this.status);

  final int? status;
}

/// The server confirmed a session.
final class SessionReadFound extends SessionRead {
  const SessionReadFound(this.response);

  final BgeSessionResponse response;
}

/// Reads a session endpoint's resolved [response].
///
/// [superseded] is asked twice: as the response resolved, and again after
/// the decode. Either `true` returns [SessionReadSuperseded] at once, ahead
/// of any answer and any throw, so a read the user's own sign-out (or, on
/// web, a newer grant) overtook is discarded rather than reported (#146).
/// [decode] is the repository's injected JSON decode (see [decodeAuthBody]).
///
/// Throws only [AuthException] subtypes. Nothing raw may leave an auth
/// method: `AuthBloc`'s handlers catch nothing wider, and a bare parse error
/// would slip past every clause and strand the form on its loading state
/// (#181).
///
/// The order below is the contract:
///
/// 1. **Superseded as the response resolved.** Checked before the status,
///    so a sign-out landing while a 401 is in flight is discarded rather
///    than settled as no session: native would otherwise clear storage for
///    a read the user had already ended.
/// 2. **The status decides first**, by the rules [readSessionStatus] holds
///    with their reasons. A 401 or 403 is [SessionReadNoSession]. Any status
///    that says nothing about the session throws [AuthServerException]
///    rather than returning no session (#98): a bodiless 502 from a proxy is
///    a server fault, never a rejection (#180).
/// 3. **The body is decoded** by [decodeAuthBody].
/// 4. **Superseded after the decode.** The decode is a suspension point,
///    since `decodeJsonBody` offloads a large body to another isolate, so a
///    sign-out can land between the first check and whatever the caller
///    does with a session: native's store would lift the sign-out latch and
///    re-persist the signed-out user's token, and web's state emission would
///    re-assert a session the user had already ended. It comes ahead of the
///    decode's failure as well, so a superseded response is discarded, not
///    reported as a server fault.
/// 5. **A body this client cannot read throws.** It is definitive when the
///    body is not JSON and INDETERMINATE when the decode itself could not be
///    performed, and only the first is a statement about the server (#352).
///    Neither is "no session": only a session the SERVER disowned may clear
///    the user's credentials.
/// 6. **An empty body or a literal JSON `null` is [SessionReadNoSession].**
///    This is the "no session" answer the status could not give, which
///    [SessionReadStatus.readBody] left to the body: BetterAuth answers an
///    absent or expired session with a 200 and no payload. Only the decoded
///    body can say so: reading "no session" off an undecoded string would
///    call a captive portal's HTML page a rejected session (#352).
/// 7. **A body that is not a JSON object throws** [AuthServerException].
/// 8. **A JSON object with the wrong fields throws** [AuthServerException],
///    wrapping the parse error so it cannot escape as a raw `TypeError`
///    (#181).
/// 9. Otherwise the session is [SessionReadFound].
Future<SessionRead> readSessionResponse(
  Response<String> response, {
  required Future<Object?> Function(String) decode,
  required bool Function() superseded,
}) async {
  if (superseded()) {
    return const SessionReadSuperseded(SessionReadCheckpoint.response);
  }

  final status = response.statusCode;

  switch (readSessionStatus(status)) {
    case SessionReadStatus.noSession:
      return SessionReadNoSession(status);
    case SessionReadStatus.undecided:
      throw AuthServerException(
        message: 'Unexpected $status from the session endpoint.',
        statusCode: status,
      );
    case SessionReadStatus.readBody:
      break;
  }

  final decoded = await decodeAuthBody(
    response.data,
    decode: decode,
    context: 'the session check',
    status: status,
  );

  if (superseded()) {
    return const SessionReadSuperseded(SessionReadCheckpoint.decode);
  }

  final failure = decoded.failure;
  if (failure != null) throw failure;

  final body = decoded.value;
  if (body == null) return SessionReadNoSession(status);

  if (body is! Map<String, dynamic>) {
    throw AuthServerException(
      message:
          'The session endpoint returned a body that is not a JSON object.',
      statusCode: status,
    );
  }

  try {
    return SessionReadFound(BgeSessionResponse.fromJson(body));
  } on Object catch (error) {
    throw AuthServerException(
      message: 'The session endpoint returned an unreadable response.',
      statusCode: status,
      cause: error,
    );
  }
}
