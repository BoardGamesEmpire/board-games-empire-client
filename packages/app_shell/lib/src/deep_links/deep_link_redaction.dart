/// Redaction of sensitive deep-link material before logging (#10).
///
/// Invitation and RSVP tokens travel as URL path segments
/// (`household/{id}/invite/{token}`, `event/{id}/rsvp/{token}`), and query
/// strings may carry anything. Logged URLs flow into breadcrumbs (#34) and
/// crash-report drafts (#69), so **no raw deep-link URI may ever be
/// logged** — everything goes through [redactDeepLinkForLog] first.
///
/// ## Why this is complete (#178)
///
/// The guarantee is an exhaustive split over what a rendered URI can
/// contain, not a list of known-bad shapes. Every component is in exactly
/// one bucket:
///
/// - **grammar-restricted** — the scheme, whose charset admits no `@`, no
///   escape and no control character, so it cannot carry anything;
/// - **replaced wholesale** — query values, the fragment, and the segment
///   after an `invite`/`rsvp` marker;
/// - **emitted as found, delimiter-checked** — the authority, every path
///   segment, every query key, each through
///   [redactDeepLinkSegmentForLog].
///
/// Nothing decoded is ever written, and `Uri.parse` normalises a literal
/// control character into an escape in every component, so a rendered link
/// cannot span log lines. Anything left is structural (a host, a
/// delimiter-free segment) and is no more sensitive than the route it
/// names — redacting *that* would leave nothing diagnosable and is the
/// line this module deliberately holds.
///
/// The sinks are enumerable and few: [DeepLinkHandler] logs the rendered
/// form on both the accept and reject branches, and
/// `NormalizedDeepLink.toString` renders its two fields. Both are covered.
library;

/// Placeholder substituted for redacted material.
const String deepLinkRedactionPlaceholder = '<redacted>';

/// Renders [uri] as a log-safe description.
///
/// The output is for humans reading logs — it is **not** a parseable URI
/// (the placeholder is deliberately not percent-encoded).
///
/// Contract (encoded by `deep_link_redaction_test.dart`):
/// - the path segment immediately following a segment equal to `invite`
///   or `rsvp` is replaced with [deepLinkRedactionPlaceholder];
/// - for a `key=value` query parameter the **value** is replaced with the
///   placeholder and the key is preserved so the link's shape stays
///   diagnosable; a **valueless** segment (no `=`) has no key/value
///   structure to preserve, so it is redacted wholesale — a bare segment
///   could itself be an opaque token, and this module is the leak-guard;
/// - a fragment, if present, is replaced wholesale with the placeholder;
/// - credential material (#178) is replaced with the placeholder, keeping
///   the `@` delimiter so the log still records that one was present. One
///   rule, applied uniformly by [redactDeepLinkSegmentForLog]: **every**
///   component emitted as found — the authority, every path segment, every
///   query key — is first checked for a credential delimiter, and anything
///   ahead of the last one is redacted. No per-case boundary (host present,
///   reject vs accept path, authority vs path) — every earlier attempt at
///   one left a leaking variant, the last being a credential percent-encoded
///   into the host itself. An email-shaped segment comes out as
///   `<redacted>@example.com`, the shape `Redaction.redactEmail` gives it
///   downstream anyway;
/// - percent-encoding cannot dodge either check: a token marker is matched
///   decoded (`%69nvite`) and a credential delimiter is matched raw in both
///   spellings (`@` and `%40`);
/// - nothing decoded is ever written to the output, so an escaped control
///   character cannot become a real one and forge a second log line;
/// - everything else — scheme, host, port, delimiter-free path segments and
///   query keys — passes through unchanged, for both raw `bge://` URIs and
///   normalized path-form locations.
String redactDeepLinkForLog(Uri uri) {
  final buffer = StringBuffer();
  if (uri.hasScheme) {
    buffer
      ..write(uri.scheme)
      ..write(':');
    // `//` only when there really is an authority: writing it
    // unconditionally rendered the authority-less `bge:user:pw@host/...`
    // form as though it had one, disguising a leak as a redacted link.
    if (uri.hasAuthority) {
      // The whole authority, through the same rule as every other emitted
      // component. `Uri.authority` is `userInfo@host:port`, so the last
      // delimiter wins and one pass covers both a real userInfo and a
      // credential smuggled into the host — a reg-name may hold escapes,
      // so `alice%3Apw%40evil` is a legal host. Taken from `authority`
      // rather than built from `host` + port: the former brackets an IPv6
      // host, and `Uri.host` does not.
      buffer
        ..write('//')
        ..write(redactDeepLinkSegmentForLog(uri.authority));
    }
  }

  // Marker checks read the ORIGINAL segments, never the mutated copy:
  // in a pathological `invite/rsvp/X` chain the `rsvp` segment itself is
  // redacted (its predecessor is `invite`), and X must STILL be redacted
  // — comparing against the already-redacted copy would let X leak.
  final original = uri.path.split('/');
  final redacted = List.of(original);
  for (var i = 0; i < original.length; i++) {
    final previous = i == 0 ? null : _decodeForInspection(original[i - 1]);
    if ((previous == 'invite' || previous == 'rsvp') &&
        original[i].isNotEmpty) {
      redacted[i] = deepLinkRedactionPlaceholder;
      continue;
    }
    redacted[i] = redactDeepLinkSegmentForLog(original[i]);
  }
  buffer.write(redacted.join('/'));

  if (uri.query.isNotEmpty) {
    buffer.write('?');
    buffer.writeAll(
      uri.query.split('&').map((parameter) {
        final separator = parameter.indexOf('=');
        if (separator == -1) {
          // No key=value structure: the whole segment is opaque and could
          // be a bare token, so redact it wholesale rather than echoing it
          // as a "key" (which would leak it).
          return deepLinkRedactionPlaceholder;
        }
        final key = redactDeepLinkSegmentForLog(
          parameter.substring(0, separator),
        );
        return '$key=$deepLinkRedactionPlaceholder';
      }),
      '&',
    );
  }

  if (uri.fragment.isNotEmpty) {
    buffer
      ..write('#')
      ..write(deepLinkRedactionPlaceholder);
  }

  return buffer.toString();
}

/// Redacts anything ahead of an `@` in a single **raw** (still-encoded)
/// [segment]. This is the one credential rule of the module, and it runs
/// on every component emitted as found: path segments, query keys, and
/// (via [NormalizedDeepLink.toString], which is why it is public) a
/// serverId logged detached from the URI it came out of.
///
/// It is deliberately not scoped to the shapes `Uri` fails to parse a
/// userInfo out of (`bge:alice:pw@host/...` with no `//`, `bge:///…` with
/// an empty authority) — those are where the shape *originates*, but a
/// credential-shaped segment leaks identically from a link with a perfect
/// host, on the accept path included. Every attempt to hold a narrower
/// boundary here left a variant open. The last `@` wins, matching how a
/// userInfo/host boundary is delimited.
///
/// The delimiter is matched on the **raw** text, in both of its spellings,
/// and the suffix is emitted raw. Decoding first would cost twice: an
/// unrelated bad escape elsewhere in the segment (`pw%40host%FF`) would
/// force the raw fallback and miss the `%40` entirely, and a decoded
/// suffix would turn `%0A` into a real newline, letting a hostile link
/// forge a second breadcrumb.
String redactDeepLinkSegmentForLog(String segment) {
  final literal = segment.lastIndexOf('@');
  final encoded = segment.lastIndexOf('%40');
  if (literal == -1 && encoded == -1) {
    return segment;
  }
  final suffix = literal > encoded
      ? segment.substring(literal + 1)
      : segment.substring(encoded + 3);
  return '$deepLinkRedactionPlaceholder@$suffix';
}

/// Decodes [segment] for inspection, falling back to the raw text when it
/// carries an escape [Uri.decodeComponent] refuses (`%FF` is not valid
/// UTF-8, and hostile links are exactly the ones that get logged).
///
/// The throw would otherwise escape `DeepLinkHandler._onUri` past *both*
/// of its log calls — and a `Stream.listen` `onError` does not catch a
/// throw from `onData` — so a malformed link would vanish from the
/// breadcrumbs entirely instead of being logged as rejected.
String _decodeForInspection(String segment) {
  try {
    return Uri.decodeComponent(segment);
  } on FormatException {
    return segment;
  }
}
