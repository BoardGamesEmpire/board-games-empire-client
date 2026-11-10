import 'package:dio/dio.dart' show Headers;
import 'package:interfaces/repositories.dart'
    show AuthRateLimitedException, parseRetryAfter;

/// The header a 429 names its wait in, as whole seconds (#559).
const String retryAfterHeader = 'x-retry-after';

/// The rate-limit exception for a 429, carrying the wait the server named in
/// [retryAfterHeader] (#559).
///
/// Shared by the native and web auth repositories, which both classify a 429
/// from Dio's [Headers].
///
/// A header sent more than once, as when a proxy adds its own beside the
/// server's, names no one wait, so the rate limit carries none. Read through
/// `Headers.value` instead, it would throw a plain `Exception`, which leaves
/// the auth method unmodelled and strands the form on its loading state.
AuthRateLimitedException rateLimitedFrom(Headers? headers) {
  final values = headers?[retryAfterHeader];
  return AuthRateLimitedException(
    retryAfter: parseRetryAfter(
      values != null && values.length == 1 ? values.single : null,
    ),
  );
}
