import 'dart:convert' show base64Url;
import 'dart:math' show Random;

/// The sessionStorage key a provider sign-in sets before it leaves the page.
/// Its value is the attempt's return id.
const String providerSignInMarkerKey = 'bge.providerSignIn.pending';

/// The query key that carries an attempt's return id on the address the
/// server sends the browser back to (#583).
const String providerSignInReturnKey = 'bge_provider_return';

/// A fresh return id for one provider sign-in: 16 random bytes, base64url
/// without padding.
///
/// The alphabet is letters, digits, `-` and `_`, which the server's check of
/// a relative callback address accepts in its query.
String newProviderSignInReturnId([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The relative address the server sends the browser back to after the
/// attempt [returnId] names, for a success and a failure alike: the app's
/// root, carrying the id under [providerSignInReturnKey]. The server adds
/// `error` (and `error_description`) to it for a failure.
String providerSignInCallback(String returnId) => Uri(
  path: '/',
  queryParameters: {providerSignInReturnKey: returnId},
).toString();

/// The two browser hooks a web provider sign-in needs, injected so the
/// VM-testable code never touches `package:web`.
final class WebProviderSignInBindings {
  const WebProviderSignInBindings({
    required this.leavePageFor,
    this.startupReturn,
  });

  /// Sets the marker to [returnId], then navigates the page to [url].
  final void Function(Uri url, String returnId) leavePageFor;

  /// What this page load brought back, read once in main().
  final WebProviderSignInReturn? startupReturn;
}

/// A page load after a provider sign-in left the page. [errorCode] is null for
/// a success.
final class WebProviderSignInReturn {
  const WebProviderSignInReturn({this.errorCode});

  final String? errorCode;
}

const String _errorKey = 'error';
const String _errorDescriptionKey = 'error_description';

/// Pure: what to make of this page load.
///
/// [marker] is the return id the marker held, or null when there was none to
/// count. This page load is the attempt's return only when the address
/// carries that same id under [providerSignInReturnKey]: the server's
/// redirect back does, and nothing the user reaches by hand in the same tab
/// does, a typed address or a bookmark included.
///
/// Not a return, a `?error=` in the address is not this tab's to report, and
/// stays where it is. A return with an `error` key (even an empty one) is a
/// failed return whose code is its first value; an empty code is not a valid
/// one, and downstream maps it to the generic failure. No `error` key is a
/// success.
///
/// [cleanedAddress] is non-null when something must leave the address bar:
/// the return id whenever the address carries one, matched or not, and
/// `error`/`error_description` with a return. Every other query parameter,
/// the path and the fragment are kept, and a query left empty is dropped
/// entirely.
///
/// A query that does not decode, such as one holding `%FF`, which is not
/// UTF-8, is no return, and the address is left as it is. This runs on every
/// page load, before `runBgeApp`, so the `FormatException` would otherwise
/// stop the app from starting on any address that carries one. The server's
/// own redirect back never does.
({WebProviderSignInReturn? startupReturn, Uri? cleanedAddress})
readProviderSignInReturn({required String? marker, required Uri address}) {
  final Map<String, List<String>> all;
  try {
    all = address.queryParametersAll;
  } on FormatException {
    return (startupReturn: null, cleanedAddress: null);
  }
  final returnIds = all[providerSignInReturnKey];
  final isReturn =
      marker != null &&
      marker.isNotEmpty &&
      returnIds != null &&
      returnIds.first == marker;

  final errors = isReturn ? all[_errorKey] : null;
  final removed = {
    providerSignInReturnKey,
    if (isReturn) ...[_errorKey, _errorDescriptionKey],
  };
  final kept = <String, List<String>>{
    for (final entry in all.entries)
      if (!removed.contains(entry.key)) entry.key: entry.value,
  };

  final WebProviderSignInReturn? startupReturn = !isReturn
      ? null
      : errors == null
      ? const WebProviderSignInReturn()
      : WebProviderSignInReturn(errorCode: errors.first);

  if (kept.length == all.length) {
    return (startupReturn: startupReturn, cleanedAddress: null);
  }
  final cleaned = kept.isEmpty
      ? Uri(
          scheme: address.scheme,
          userInfo: address.userInfo,
          host: address.hasAuthority ? address.host : null,
          port: address.hasPort ? address.port : null,
          path: address.path,
          fragment: address.hasFragment ? address.fragment : null,
        )
      : address.replace(queryParameters: kept);

  return (startupReturn: startupReturn, cleanedAddress: cleaned);
}
