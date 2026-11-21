import 'package:app_shell/src/deep_links/deep_link_normalizer.dart';
import 'package:server_onboarding/server_onboarding.dart';

/// The address a `bge://server/...` link can carry, so a device that does
/// not know the server yet can offer to add it (#971).
///
/// [ServerDeepLink.address] is derived from the link's location rather than
/// stored beside it: the location stays the one source of truth, and the
/// redaction in `ServerDeepLink.toString` already covers the address because
/// it covers the whole query.

/// The query parameter that holds the server's base URL.
const linkAddressParam = 'address';

/// The validated, normalized server address in [location]'s query, or null.
///
/// Null covers every refusal, so a caller never has to tell them apart:
/// - no `address`, an empty one, or more than one (which one is meant?);
/// - a query that cannot be decoded;
/// - a value containing `@`: [normalizeServerUrl] rebuilds a URL without its
///   userinfo instead of rejecting it, so `https://alice:pw@host` would
///   otherwise turn into a plausible-looking `https://host`. A link that
///   smuggles credentials is refused outright;
/// - a value [normalizeServerUrl] rejects (another scheme, plain http to a
///   public host, a malformed host).
///
/// Never throws, and never reaches the network.
String? serverLinkAddress(String location) {
  final List<String>? values;
  try {
    values = Uri.parse(location).queryParametersAll[linkAddressParam];
  } on FormatException {
    return null;
  }
  if (values == null || values.length != 1) return null;

  final value = values.single;
  if (value.isEmpty || value.contains('@')) return null;

  final result = normalizeServerUrl(value);
  return switch (result) {
    ServerUrlValid(:final normalized) => normalized,
    ServerUrlInvalid() => null,
  };
}

/// The [ServerDeepLink] a router [location] stands for, or null when it is
/// anything else.
///
/// Re-runs the location through [normalizeDeepLink] as a `bge://` link, so it
/// accepts exactly what a link may carry. A location that cannot be parsed,
/// an app location, and a server location with no resource path or an
/// undecodable id all come back null.
ServerDeepLink? serverDeepLinkFromLocation(String location) {
  final Uri uri;
  try {
    uri = Uri.parse('bge:/$location');
  } on FormatException {
    return null;
  }
  return switch (normalizeDeepLink(uri)) {
    DeepLinkNormalized(:final ServerDeepLink link) => link,
    _ => null,
  };
}
