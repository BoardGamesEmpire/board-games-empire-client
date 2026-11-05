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
AuthRateLimitedException rateLimitedFrom(Headers? headers) =>
    AuthRateLimitedException(
      retryAfter: parseRetryAfter(headers?.value(retryAfterHeader)),
    );
