/// Reduces a request URI to `scheme://host[:port]/path` for diagnostic
/// logging.
///
/// [Uri.toString] includes the query string, fragment, and userInfo — any of
/// which can carry tokens or PII. Rebuilding from the safe components only
/// upholds the "never log query parameters / userInfo / tokens" contract that
/// the TEMP auth diagnostics share (#101, removed by #100), while still
/// surfacing an empty or malformed baseUrl (a missing scheme/host means the
/// baseUrl never resolved).
///
/// Shared by [DevLogInterceptor] and the auth repository so the two redact
/// identically; both call sites disappear when #100 lands.
String redactUri(Uri uri) => Uri(
  scheme: uri.hasScheme ? uri.scheme : null,
  host: uri.host.isEmpty ? null : uri.host,
  port: uri.hasPort ? uri.port : null,
  path: uri.path,
).toString();
