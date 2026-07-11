/// Redaction of sensitive deep-link material before logging (#10).
///
/// Invitation and RSVP tokens travel as URL path segments
/// (`household/{id}/invite/{token}`, `event/{id}/rsvp/{token}`), and query
/// strings may carry anything. Logged URLs flow into breadcrumbs (#34) and
/// crash-report drafts (#69), so **no raw deep-link URI may ever be
/// logged** — everything goes through [redactDeepLinkForLog] first.
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
/// - everything else — scheme, authority, non-token path segments, query
///   keys — passes through unchanged, for both raw `bge://` URIs and
///   normalized path-form locations.
String redactDeepLinkForLog(Uri uri) {
  final buffer = StringBuffer();
  if (uri.hasScheme) {
    buffer
      ..write(uri.scheme)
      ..write('://')
      ..write(uri.authority);
  }

  // Marker checks read the ORIGINAL segments, never the mutated copy:
  // in a pathological `invite/rsvp/X` chain the `rsvp` segment itself is
  // redacted (its predecessor is `invite`), and X must STILL be redacted
  // — comparing against the already-redacted copy would let X leak.
  final original = uri.path.split('/');
  final redacted = List.of(original);
  for (var i = 1; i < original.length; i++) {
    final previous = Uri.decodeComponent(original[i - 1]);
    if ((previous == 'invite' || previous == 'rsvp') &&
        original[i].isNotEmpty) {
      redacted[i] = deepLinkRedactionPlaceholder;
    }
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
        final key = parameter.substring(0, separator);
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
