import 'package:dio/dio.dart' show DioException, Headers, Options, Response;
import 'package:dio_network/src/auth/auth_wire_errors.dart';
import 'package:dio_network/src/auth/rate_limited.dart';
import 'package:http_status/http_status.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

// The sign-in methods requests the native `AuthRepositoryImpl` and the web
// `WebAuthRepositoryImpl` both send (#582). The paths, the sending and its
// refusal classification, and the reading of the list live here so the two
// cannot read one answer two ways. Each repository keeps its own
// `_plainBody` (#360) and passes it in.

final BgeLogger _log = BgeLogger('bge.auth.sign_in_methods');

/// Where the signed-in user's sign-in methods are listed.
String listSignInMethodsPath(ServerIdentity identity) =>
    '${identity.authBasePath}/list-accounts';

/// Where a provider link is started.
String linkProviderPath(ServerIdentity identity) =>
    '${identity.authBasePath}/link-social';

/// Where a sign-in method is removed.
String unlinkSignInMethodPath(ServerIdentity identity) =>
    '${identity.authBasePath}/unlink-account';

/// Sends a sign-in methods request and returns its 2xx response.
///
/// [send] makes the request with [options], the calling repository's own
/// plain-body options (#360), so a body arrives as text. A non-2xx leaves as
/// [signInMethodsRefusal]'s answer, whether the Dio resolved it (a platform
/// factory's permissive `validateStatus`) or threw it as a `badResponse` (an
/// injected Dio's default): both are classified by status and body. A thrown
/// failure with no response is transport and leaves as
/// [mapAuthDioException]'s answer. [context] names the operation in a
/// refusal's log and message.
Future<Response<String>> sendSignInMethodsRequest(
  Future<Response<String>> Function(Options options) send, {
  required Options options,
  required String context,
}) async {
  Response<String> response;
  try {
    response = await send(options);
  } on DioException catch (e) {
    final thrown = e.response;
    if (thrown?.statusCode == null) {
      throw mapAuthDioException(e, credentialGrant: false);
    }
    response = Response<String>(
      requestOptions: e.requestOptions,
      statusCode: thrown!.statusCode,
      headers: thrown.headers,
      data: thrown.data is String ? thrown.data as String : null,
    );
  }

  if (!isAuthSuccessStatus(response.statusCode)) {
    throw signInMethodsRefusal(
      response.statusCode,
      response.data,
      headers: response.headers,
      context: context,
    );
  }

  return response;
}

/// Reads the [SignInMethod]s from a 2xx `list-accounts` [response].
///
/// [decode] is the calling repository's own injected JSON decode, as
/// [decodeAuthBody] takes it. A body that is not JSON throws
/// [AuthServerException], and a decode that could not run throws
/// [AuthLocalDecodeException]. A body [parseSignInMethods] cannot read
/// throws [AuthServerException] for the response's status, carrying the
/// parse error.
Future<List<SignInMethod>> readSignInMethods(
  Response<String> response, {
  required Future<Object?> Function(String) decode,
}) async {
  final body = await decodeAuthBody(
    response.data,
    decode: decode,
    context: 'listing sign-in methods',
    status: response.statusCode,
  );
  final failure = body.failure;
  if (failure != null) throw failure;

  try {
    return parseSignInMethods(body.value);
  } on FormatException catch (error) {
    throw AuthServerException(
      message: 'The server answered an unreadable list of sign-in methods.',
      statusCode: response.statusCode,
      cause: error,
    );
  }
}

/// Reads a `list-accounts` body into [SignInMethod]s.
///
/// Throws [FormatException] for a body that is not a list, a row that is not
/// an object, or a row without a string `id` and `providerId`. Unknown keys
/// are ignored. A missing or unreadable `createdAt` leaves
/// [SignInMethod.linkedAt] null.
List<SignInMethod> parseSignInMethods(Object? decoded) {
  if (decoded is! List) {
    throw const FormatException('list-accounts did not answer a list.');
  }

  return [
    for (final row in decoded)
      if (row is Map)
        _parseRow(row)
      else
        throw const FormatException('A list-accounts row is not an object.'),
  ];
}

SignInMethod _parseRow(Map<Object?, Object?> row) {
  final id = row['id'];
  final providerId = row['providerId'];
  if (id is! String || id.isEmpty || providerId is! String) {
    throw const FormatException('A list-accounts row lacks an id.');
  }

  final createdAt = row['createdAt'];
  return SignInMethod(
    id: id,
    providerId: providerId,
    linkedAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
  );
}

/// The [AuthException] a non-2xx answer to a sign-in methods request means.
///
/// A 429 is the rate limit, with its wait read from [headers]. A rejection
/// body that carries a `code` is an [AuthProviderLinkException] with the
/// reason that code maps to. Anything else is an [AuthServerException] for
/// [status].
///
/// Logs the status and the code only, never the body or its message.
AuthException signInMethodsRefusal(
  int? status,
  Object? body, {
  required String context,
  Headers? headers,
}) {
  if (status == HttpStatusCode.tooManyRequests) {
    _log.warn('Sign-in methods rate limited', context: {'status': status});
    return rateLimitedFrom(headers);
  }

  final code = authRejectionCode(body);
  _log.warn(
    'Sign-in methods request refused',
    context: {'status': status, 'code': code, 'operation': context},
  );

  if (code != null) {
    return AuthProviderLinkException(
      ProviderLinkFailureReason.forCode(code),
      code: code,
    );
  }

  return AuthServerException(
    message: 'Unexpected $status during $context.',
    statusCode: status,
  );
}
