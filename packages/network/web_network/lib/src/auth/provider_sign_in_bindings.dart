import 'dart:convert' show base64Url;
import 'dart:math' show Random;

/// The sessionStorage key a provider sign-in or link sets before it leaves
/// the page. Its value is the marker: the attempt's bare return id for a
/// sign-in, and [providerLinkMarker] for a link (#582).
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

/// The marker a provider link sets before it leaves the page (#582):
/// `link:`, the provider id, `:`, and the attempt's return id.
///
/// The purpose rides in the marker so that a link's return is never read as
/// a sign-in. Neither part holds a `:`: provider ids are `[a-z0-9-]`, and
/// return ids are base64url ([newProviderSignInReturnId]). Nor does a bare
/// return id start with `link:`, so the two kinds of marker cannot be
/// mistaken for each other.
String providerLinkMarker(String providerId, String returnId) =>
    '$_linkMarkerPrefix$providerId:$returnId';

/// The relative address the server sends the browser back to after the link
/// attempt [returnId] names (#582), for a success and a failure alike:
/// [returnPath], carrying the id under [providerSignInReturnKey]. The server
/// adds `error` (and `error_description`) to it for a failure.
String providerLinkCallback(String returnPath, String returnId) => Uri(
  path: returnPath,
  queryParameters: {providerSignInReturnKey: returnId},
).toString();

/// The two browser hooks a web provider sign-in or link needs, injected so
/// the VM-testable code never touches `package:web`.
final class WebProviderSignInBindings {
  const WebProviderSignInBindings({
    required this.leavePageFor,
    this.startupReturn,
  });

  /// Sets the marker to `marker`, then navigates the page to `url`.
  ///
  /// `marker` is a sign-in's bare return id, or a link's
  /// [providerLinkMarker].
  final void Function(Uri url, String marker) leavePageFor;

  /// What this page load brought back, read once in main().
  final WebProviderSignInReturn? startupReturn;
}

/// A page load after a provider sign-in or link left the page. [errorCode] is
/// null for a success.
final class WebProviderSignInReturn {
  const WebProviderSignInReturn({this.errorCode, this.linkProviderId});

  final String? errorCode;

  /// The provider a link's return was for, or null for a sign-in's return
  /// (#582).
  final String? linkProviderId;
}

const String _errorKey = 'error';
const String _errorDescriptionKey = 'error_description';
const String _linkMarkerPrefix = 'link:';

/// What [marker] says: the return id to match, and for a link the provider.
/// Null for no marker: none at all, an empty one, or a `link:` marker that
/// does not split into a provider id and a return id, both non-empty.
///
/// A `link:` marker is never read as a sign-in's bare return id.
({String returnId, String? linkProviderId})? _readMarker(String? marker) {
  if (marker == null || marker.isEmpty) return null;
  if (!marker.startsWith(_linkMarkerPrefix)) {
    return (returnId: marker, linkProviderId: null);
  }

  final rest = marker.substring(_linkMarkerPrefix.length);
  final split = rest.indexOf(':');
  if (split <= 0 || split == rest.length - 1) return null;
  return (
    returnId: rest.substring(split + 1),
    linkProviderId: rest.substring(0, split),
  );
}

/// Pure: what to make of this page load.
///
/// [marker] is what the marker held, or null when there was none to count:
/// a sign-in's bare return id, or a link's [providerLinkMarker] (#582). This
/// page load is the attempt's return only when the address carries the
/// marker's return id under [providerSignInReturnKey]: the server's redirect
/// back does, and nothing the user reaches by hand in the same tab does, a
/// typed address or a bookmark included. A link's return names its provider
/// in [WebProviderSignInReturn.linkProviderId], and is never a sign-in's.
///
/// Not a return, a `?error=` in the address is not this tab's to report, and
/// stays where it is. A return with an `error` key (even an empty one) is a
/// failed return whose code is its first value; an empty code is not a valid
/// one, and downstream maps it to the generic failure. No `error` key is a
/// success.
///
/// `cleanedAddress` is non-null when something must leave the address bar:
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
  final read = _readMarker(marker);
  final isReturn =
      read != null && returnIds != null && returnIds.first == read.returnId;

  final errors = isReturn ? all[_errorKey] : null;
  final removed = {
    providerSignInReturnKey,
    if (isReturn) ...[_errorKey, _errorDescriptionKey],
  };
  final kept = <String, List<String>>{
    for (final entry in all.entries)
      if (!removed.contains(entry.key)) entry.key: entry.value,
  };

  final startupReturn = !isReturn
      ? null
      : WebProviderSignInReturn(
          errorCode: errors?.first,
          linkProviderId: read.linkProviderId,
        );

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
