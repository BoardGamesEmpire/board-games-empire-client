import 'package:dio/dio.dart';
import 'package:dio_network/src/auth/auth_wire_errors.dart';
import 'package:dio_network/src/network/redact_uri.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

// The email/password requests the native `AuthRepositoryImpl` and the web
// `WebAuthRepositoryImpl` both send (#877). Each repository keeps what it
// does before the request (native retires a pending provider sign-in) and
// everything after the response: its grant handling differs on purpose.

/// The email/password strategy [identity] advertises.
///
/// Throws [AuthServerException] when it advertises none. Given a [log], it
/// first logs that as an error naming [dio]'s base URL, redacted. Both
/// repositories pass their logger and their Dio (#995).
///
/// [dio]'s options are read only when the strategy is missing: the base URL
/// is there to name the server in that log line, and a sign-in that has its
/// strategy needs nothing from them.
///
/// [log] and [dio] come together or not at all. A logger alone would log an
/// empty `base_url`, which [redactUri]'s doc reads as a base URL that never
/// resolved, and a Dio alone would go nowhere.
EmailAndPasswordStrategy requireEmailPasswordStrategy(
  ServerIdentity identity, {
  BgeLogger? log,
  Dio? dio,
}) {
  assert(
    (log == null) == (dio == null),
    'Pass log and dio together, or neither.',
  );
  final strategy = identity.emailAndPasswordStrategy;
  if (strategy == null) {
    // A cached ServerIdentity lacking an email/password strategy is a
    // server-side contract problem (its well-known advertised no such
    // strategy), surfaced BEFORE any HTTP call — so neither the network
    // interceptor nor the bloc has the context to log it. Log here.
    log?.error(
      'Email/password strategy missing on cached identity',
      context: {
        // Redacted (userInfo/query/fragment stripped) — the auth
        // diagnostics never log raw URLs (PR #103 review).
        'base_url': redactUri(
          Uri.tryParse(dio?.options.baseUrl ?? '') ?? Uri(),
        ),
        'has_strategies': identity.strategies.isNotEmpty,
        'strategy_count': identity.strategies.length,
      },
    );
    throw const AuthServerException(
      message: 'This server does not support email/password authentication.',
    );
  }

  return strategy;
}

/// POSTs [email] and [password] to [strategy]'s sign-in endpoint and returns
/// the response with its body as untouched text.
///
/// A thrown [DioException] leaves as [mapAuthDioException]'s credential-grant
/// answer. A resolved response is returned whatever its status: the caller's
/// grant check settles it.
Future<Response<String>> postSignIn(
  Dio dio,
  EmailAndPasswordStrategy strategy, {
  required String email,
  required String password,
}) async {
  try {
    return await dio.post<String>(
      strategy.signInEndpoint,
      data: {'email': email, 'password': password},
      options: _plainBody,
    );
  } on DioException catch (e) {
    throw mapAuthDioException(e, credentialGrant: true);
  }
}

/// POSTs a new account to [strategy]'s sign-up endpoint and returns the
/// response with its body as untouched text.
///
/// Throws [AuthRegistrationDisabledException] before any request when
/// [strategy] has sign-up disabled or names no sign-up endpoint. A thrown
/// [DioException] leaves as [mapAuthDioException]'s credential-grant answer.
/// A resolved response is returned whatever its status: the caller's grant
/// check settles it.
Future<Response<String>> postSignUp(
  Dio dio,
  EmailAndPasswordStrategy strategy, {
  required String email,
  required String password,
  required String username,
  String? firstName,
  String? lastName,
}) async {
  if (strategy.signUpDisabled || strategy.signUpEndpoint == null) {
    throw const AuthRegistrationDisabledException();
  }

  try {
    return await dio.post<String>(
      strategy.signUpEndpoint!,
      data: {
        'email': email,
        'password': password,
        // BetterAuth's email-register validator requires `name`. The
        // server maps name → username at the model layer, but that
        // mapping does not rewrite the inbound validator, so the wire
        // key must be `name`. This is purely the HTTP boundary — the
        // field is "username" everywhere user-facing (UI label, form,
        // AuthRegisterRequested.username).
        'name': username,
        'firstName': ?firstName,
        'lastName': ?lastName,
      },
      options: _plainBody,
    );
  } on DioException catch (e) {
    throw mapAuthDioException(e, credentialGrant: true);
  }
}

/// Pins `responseType` so an **injected** Dio cannot put a non-`String` in
/// the body.
///
/// `DioMixin.fetch` forces `responseType` from `T`, but skips that entirely
/// when the instance is already `bytes` or `stream`
/// (`dio-5.11.0/lib/src/dio_mixin.dart:419-421`). `assureResponse` then
/// casts a `Uint8List` to `String` and the `TypeError` escapes as
/// `DioException(type: unknown)` with no response attached — the status gone
/// before anything can classify it, which is #352's bug by another door.
/// Both auth repositories take an arbitrary `Dio` by constructor and hand it
/// here, so the type argument alone is not enough (#360).
///
/// A fresh instance per call: `Options` is mutable, and one shared instance
/// is a shared mutable default waiting to be edited. Private to this file,
/// as each repository's own `_plainBody` is to its class (#360).
Options get _plainBody => Options(responseType: ResponseType.plain);
