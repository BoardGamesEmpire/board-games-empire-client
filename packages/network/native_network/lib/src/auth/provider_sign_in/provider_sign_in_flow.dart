import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:http_status/http_status.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart' show ProviderSignInBrowser;
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:native_network/src/auth/provider_sign_in/app_sign_in_return_address.dart';
import 'package:native_network/src/auth/provider_sign_in/pkce.dart';
import 'package:native_network/src/auth/provider_sign_in/provider_sign_in_attempt.dart';
import 'package:native_network/src/auth/provider_sign_in/server_address.dart';
import 'package:observability/observability.dart';

/// Adopts a provider sign-in's successful token response as the repository's
/// grant (#879).
///
/// [requireCurrent] throws `AuthSupersededException` unless the attempt the
/// response answers is still the one the flow holds. The adopter calls it
/// after the body is read, which can suspend on a large body, and before the
/// grant is adopted.
typedef ProviderGrantAdopter = Future<AuthResponse> Function(
  Response<String> response, {
  required void Function() requireCurrent,
});

/// Native app sign-in (#583) for one server's `AuthRepositoryImpl` (#879): a
/// PKCE pair and a `state`, the in-app browser tab, the checks on what it
/// returns, then the code exchange at the token route the attempt recorded
/// when it started. The repository adopts the grant the exchange returns.
final class ProviderSignInFlow {
  ProviderSignInFlow({
    required this._dio,
    required this._browser,
    required this._serverUrl,
    required this._log,
  });

  final Dio _dio;

  /// The in-app browser tab provider sign-in runs in (#583).
  final ProviderSignInBrowser _browser;

  /// The address discovery was fetched from (`ServerConfig.serverUrl`). A
  /// return's `iss` must name it, and the provider routes resolve against it
  /// (#583).
  final String _serverUrl;

  /// The repository's logger, so every record keeps its name.
  final BgeLogger _log;

  /// The provider sign-in waiting on its browser tab or its code exchange
  /// (#583). One per repository: a new attempt replaces it, and a sign-out, a
  /// password sign-in or sign-up, and the repository's `onDispose` retire it,
  /// so a return for anything but the attempt held here adopts nothing.
  ///
  /// Attempts live here, in the per-server repository's flow, so a return is
  /// only ever adopted by the server its attempt started on. The repository's
  /// `onDispose` runs when that server is removed or suspended. A server
  /// switch only backgrounds the server and keeps the repository, so an
  /// attempt open across a switch still finishes there, into this server's
  /// own token storage.
  ProviderSignInAttempt? _pendingAttempt;

  /// Whether this device has an in-app browser tab to run provider sign-in in.
  bool get isDeviceSupported => _browser.isSupported;

  /// Ends the pending provider sign-in, if there is one, for a newer intent
  /// (#583). Synchronous, so that it lands before the caller's first await:
  /// the tab's late return then finds no attempt, throws
  /// [AuthSupersededException] and stores nothing.
  void retire() => _pendingAttempt = null;

  /// Runs a provider sign-in for [strategy] and hands a successful token
  /// response to [adopt].
  ///
  /// The attempt is recorded before the tab opens and dropped when this call
  /// ends, but only while it is still the one held: a newer attempt that
  /// replaced it stays pending.
  Future<ProviderSignInOutcome> run(
    OidcStrategy strategy, {
    required ProviderGrantAdopter adopt,
  }) async {
    final start = resolveServerEndpoint(_serverUrl, strategy.appSignInEndpoint);
    final tokenEndpoint = resolveServerEndpoint(
      _serverUrl,
      strategy.appTokenEndpoint,
    );
    if (start == null || tokenEndpoint == null) {
      // A discovery path no address can be made from, or an absolute one off
      // this server's origin. Refused here, before the tab opens or any
      // request goes out, as a modelled exception: a raw FormatException
      // would strand the caller on its loading state (#181).
      _log.warn(
        'Refusing to start a provider sign-in whose routes are not addresses '
        'on this server',
        context: {'check': 'endpoint'},
      );
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'The server sent a provider sign-in route that is not valid.',
      );
    }

    final attempt = ProviderSignInAttempt(
      state: randomUrlSafeToken(),
      codeVerifier: randomUrlSafeToken(),
      providerId: strategy.providerId,
      tokenEndpoint: tokenEndpoint,
      issuerAddress: _serverUrl,
    );
    _pendingAttempt = attempt;

    try {
      return await _runProviderSignIn(attempt, start, adopt);
    } finally {
      if (identical(_pendingAttempt, attempt)) _pendingAttempt = null;
    }
  }

  /// Opens the tab for [attempt] at the start route [start], checks its return
  /// and exchanges its code.
  Future<ProviderSignInOutcome> _runProviderSignIn(
    ProviderSignInAttempt attempt,
    Uri start,
    ProviderGrantAdopter adopt,
  ) async {
    final url = start.replace(
      queryParameters: {
        ...start.queryParameters,
        'provider': attempt.providerId,
        'redirect_uri': appSignInReturnAddress,
        'code_challenge': codeChallengeS256(attempt.codeVerifier),
        'code_challenge_method': 'S256',
        'state': attempt.state,
      },
    );

    final Uri? returned;
    try {
      returned = await _browser.authenticate(
        url: url,
        callbackScheme: appSignInCallbackScheme,
      );
    } on AuthException {
      // A replaced attempt ends quietly, even when its tab failed.
      _requirePendingAttempt(attempt);
      rethrow;
    } on Object catch (error, stackTrace) {
      _requirePendingAttempt(attempt);
      // The seam promises an AuthProviderSignInException; anything else is
      // wrapped, so nothing raw leaves an auth method (#181).
      Error.throwWithStackTrace(
        AuthProviderSignInException(
          ProviderSignInFailureReason.generic,
          message: 'The in-app browser tab failed.',
          cause: error,
        ),
        stackTrace,
      );
    }

    _requirePendingAttempt(attempt);

    if (returned == null) return const ProviderSignInCancelled();

    final failedCheck = _failedReturnCheck(returned, attempt);
    if (failedCheck != null) {
      _log.warn(
        'Refusing a provider sign-in return that failed a check',
        context: {'check': failedCheck},
      );
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'The provider sign-in return failed a check.',
      );
    }

    final query = returned.queryParameters;

    // Mapped by the code alone. `error_description` is optional, comes in the
    // server's fallback locale, and is never shown or logged.
    final error = query['error'];
    if (error != null) {
      _log.warn(
        'The provider sign-in came back with an error',
        context: {'code': error},
      );
      throw AuthProviderSignInException(
        ProviderSignInFailureReason.forCode(error),
        code: error,
      );
    }

    final code = query['code'];
    if (code == null || code.isEmpty) {
      _log.warn(
        'Refusing a provider sign-in return that failed a check',
        context: {'check': 'code'},
      );
      throw const AuthProviderSignInException(
        ProviderSignInFailureReason.generic,
        message: 'The provider sign-in return carried no code.',
      );
    }

    return ProviderSignInCompleted(
      await _exchangeProviderCode(attempt, code, adopt),
    );
  }

  /// The name of the first check [returned] fails for [attempt], or null when
  /// it passes them all. Only the name is ever logged, never the address, its
  /// `state` or its code.
  ///
  /// Runs before `error` is read. The server echoes the app's `state` on
  /// every return it sends, failures included, so an error return that fails
  /// these is not this attempt's to report.
  ///
  /// A query that does not decode, such as one holding `%FF`, which is not
  /// UTF-8, fails the `query` check. Read raw, its `FormatException` would
  /// leave the auth method unmodelled and strand the caller on its loading
  /// state (#181). Once this passes, the query decodes for the reads after it.
  static String? _failedReturnCheck(
    Uri returned,
    ProviderSignInAttempt attempt,
  ) {
    if (returned.scheme.toLowerCase() != appSignInCallbackScheme ||
        returned.host.toLowerCase() != appSignInReturnHost) {
      return 'return_address';
    }

    final Map<String, String> query;
    try {
      query = returned.queryParameters;
    } on FormatException {
      return 'query';
    }
    if (query['state'] != attempt.state) return 'state';

    // RFC 9207 section 2.4: compared with the address this attempt was
    // started against, never with an issuer some other response supplied.
    final iss = query['iss'];
    if (iss == null || !isSameServerAddress(iss, attempt.issuerAddress)) {
      return 'iss';
    }

    return null;
  }

  /// Exchanges [code] at the token route [attempt] recorded and hands the
  /// answer to [adopt], which adopts the grant the way a password sign-in
  /// does.
  Future<AuthResponse> _exchangeProviderCode(
    ProviderSignInAttempt attempt,
    String code,
    ProviderGrantAdopter adopt,
  ) async {
    late final Response<String> response;
    try {
      // Absolute, so the Dio's base URL plays no part: the recorded route is
      // the only one this code goes to.
      response = await _dio.postUri<String>(
        attempt.tokenEndpoint,
        data: {'code': code, 'code_verifier': attempt.codeVerifier},
        options: _plainBody,
      );
    } on DioException catch (e) {
      _requirePendingAttempt(attempt);
      // A thrown rejection (an injected Dio that throws on a non-2xx) is
      // worded the same as a resolved one.
      throw _tokenRouteRefusal(e.response?.statusCode, e.response?.data) ??
          mapAuthDioException(e, credentialGrant: true);
    }

    // The answer may land after the attempt was replaced or its server scope
    // closed. Either way the grant is not this repository's to adopt.
    _requirePendingAttempt(attempt);

    final refusal = _tokenRouteRefusal(response.statusCode, response.data);
    if (refusal != null) throw refusal;

    // The adopter checks again after the decode, which can suspend on a large
    // body.
    return adopt(
      response,
      requireCurrent: () => _requirePendingAttempt(attempt),
    );
  }

  /// A refusal from the token route that names its reason: a 4xx other than a
  /// 429 whose envelope carries a `code`, read under the same bound as every
  /// other rejection envelope. A code outside
  /// [ProviderSignInFailureReason.forCode]'s table, `BANNED_USER` among them,
  /// is the generic refusal.
  ///
  /// Null for anything else, which is classified as every credential grant
  /// is: a 429 is a rate limit whatever its body says (#559), and a 5xx or a
  /// rejection with no readable code is not a refusal the provider flow can
  /// word.
  AuthProviderSignInException? _tokenRouteRefusal(int? status, Object? body) {
    if (status == null ||
        status == HttpStatusCode.tooManyRequests ||
        status < HttpStatusCode.badRequest ||
        status >= HttpStatusCode.internalServerError) {
      return null;
    }

    final code = authRejectionCode(body);
    if (code == null) return null;

    _log.warn(
      'The server refused the provider sign-in code',
      context: {'code': code, 'status': status},
    );
    return AuthProviderSignInException(
      ProviderSignInFailureReason.forCode(code),
      code: code,
    );
  }

  /// Throws [AuthSupersededException] unless [attempt] is still the one this
  /// flow holds: a newer attempt replaced it, or the repository's `onDispose`
  /// dropped it when its server scope closed.
  void _requirePendingAttempt(ProviderSignInAttempt attempt) {
    if (identical(_pendingAttempt, attempt)) return;

    _log.info(
      'Discarding a provider sign-in that was replaced or whose server '
      'scope closed',
    );
    throw const AuthSupersededException(
      message:
          'The provider sign-in was replaced by a newer attempt, or its '
          'server was closed.',
    );
  }

  /// Pins `responseType` so an **injected** Dio cannot put a non-`String` in
  /// the code exchange's body. A fresh instance per call, as the repository's
  /// own `_plainBody` is: `Options` is mutable, and one shared across call
  /// sites is a shared mutable default waiting to be edited (#360).
  static Options get _plainBody => Options(responseType: ResponseType.plain);
}
