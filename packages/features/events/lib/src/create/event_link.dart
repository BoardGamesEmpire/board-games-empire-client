/// Whether [link] is one the server's `@IsUrl()` takes, and an http or
/// https link with a host (#499).
///
/// A link the server refuses would be refused only once it is sent, which
/// parks the create under a banner that blames who's invited. So this
/// checks what the server's check does: validator.js 13.15.35's `isURL`,
/// with its defaults.
///
/// - At most 2084 characters, with no whitespace, `<` or `>`.
/// - Credentials, if any, as `name:password`, the two not both empty, and
///   a port, if any, from 1 to 65535.
/// - A host that is an IPv4 address, or a name with a top-level domain: at
///   least two letters, or one spelt `xn--` as international ones are. Each
///   of its labels is at most 63 letters, digits and inner hyphens, with no
///   underscore.
///
/// The host is read as typed, as the server reads it. Dart's parser decodes
/// some escapes in a host and encodes others, so its `host` can pass a name
/// the server refuses, or refuse one it takes.
///
/// It is stricter than the server in two ways, by choice. It takes only
/// http and https links written out with `//` and a host, which open as
/// they are, where the server also takes `example.com` and `ftp:`. And it
/// takes no bare IPv6 address.
bool isFullLink(String link) {
  if (link.length > _longestLink || _notInLink.hasMatch(link)) return false;
  final uri = Uri.tryParse(link);
  if (uri == null ||
      !(uri.isScheme('http') || uri.isScheme('https')) ||
      // As typed: Dart's parser reads a `\` there as a `/`, and the server
      // refuses it.
      !link.startsWith('://', uri.scheme.length)) {
    return false;
  }

  // What follows `scheme://`, up to the path, query or fragment.
  final rest = link.substring(uri.scheme.length + '://'.length);
  var authority = rest.substring(0, _authorityEnd(rest));
  final at = authority.indexOf('@');
  if (at != -1) {
    final credentials = authority.substring(0, at);
    if (credentials.isEmpty ||
        credentials == ':' ||
        ':'.allMatches(credentials).length > 1) {
      return false;
    }
    authority = authority.substring(at + 1);
  }
  if (authority.startsWith('[')) return false;

  final colon = authority.indexOf(':');
  final host = colon == -1 ? authority : authority.substring(0, colon);
  final port = colon == -1 ? '' : authority.substring(colon + 1);
  if (port.isNotEmpty) {
    final number = _digits.hasMatch(port) ? int.tryParse(port) : null;
    if (number == null || number < 1 || number > _highestPort) return false;
  }
  return _ipv4.hasMatch(host) || _isDomainName(host);
}

/// Where a link's authority ends in [rest], what follows its `scheme://`:
/// at the first `/`, `?` or `#`, or at the end.
int _authorityEnd(String rest) {
  final end = rest.indexOf(RegExp('[/?#]'));
  return end == -1 ? rest.length : end;
}

/// Whether [host] is a name with a top-level domain, in labels a name may
/// have.
bool _isDomainName(String host) {
  final labels = host.split('.');
  return labels.length > 1 &&
      _topLevelLabel.hasMatch(labels.last) &&
      labels.every(_label.hasMatch);
}

/// The longest link the server takes.
const _longestLink = 2084;

const _highestPort = 65535;

/// What no link may hold anywhere.
final _notInLink = RegExp(r'[\s<>]');

/// Four numbers from 0 to 255, with no leading zeros, joined by dots.
final _ipv4 = RegExp(
  r'^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}'
  r'(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$',
);

/// A top-level domain: two letters or more, in any script, or an
/// international one in its `xn--` spelling.
final _topLevelLabel = RegExp(
  '^(?:[a-z\u{a1}-\u{a8}\u{aa}-\u{d7ff}\u{f900}-\u{fdcf}\u{fdf0}-\u{ffef}]{2,}'
  r'|xn[a-z0-9-]{2,})$',
  caseSensitive: false,
);

/// One label of a name: up to 63 letters, digits and hyphens, with no
/// hyphen at either end, and no underscore or full-width form.
final _label = RegExp(
  '^(?!-)(?!.*-\$)[a-z0-9\u{a1}-\u{ff00}\u{ff5f}-\u{ffff}-]{1,63}\$',
  caseSensitive: false,
);

/// Digits alone, as a port is: `int.tryParse` would also take a sign.
final _digits = RegExp(r'^[0-9]+$');
