/// Shared redaction utilities (issue #8).
///
/// Promoted from the helpers formerly private to
/// `packages/features/auth/lib/src/bloc/auth_event.dart` so that any code
/// needing to redact before logging — event `toString`s, the
/// BreadcrumbBuffer, future analytics sinks — has one consistent place to
/// reach. [redactName] and [redactEmail] are behaviour-identical to the
/// originals; `redaction_test.dart` pins the exact output shapes.
///
/// ## Threat-model caveat
///
/// Partial redaction is incidental-exposure mitigation, not strong
/// anonymisation. The patterns are deterministic so debug readers can
/// correlate events for the same user, which equally means a determined
/// attacker combining multiple lines with external context can narrow
/// identity for short values. Deployments needing GDPR-grade anonymisation
/// should mask fully or suppress at the sink layer.
abstract final class Redaction {
  /// The replacement string used by [redactJsonFields] by default, and the
  /// conventional marker for "a value was here and was removed".
  static const String defaultReplacement = '<redacted>';

  static final RegExp _emailPattern = RegExp(
    r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
  );

  /// Partial name redaction.
  ///
  /// - empty → empty
  /// - 1–2 chars → all `*`
  /// - 3+ chars → first + `*` × (length − 2) + last
  ///
  /// Examples: `John` → `J**n`; `Bob` → `B*b`; `Al` → `**`; `X` → `*`.
  static String redactName(String name) => maskMiddle(name);

  /// Partial email redaction.
  ///
  /// Splits the local part on `.`, applies [redactName] to each segment,
  /// rejoins, and preserves the domain intact — the domain is useful debug
  /// context (gmail vs corporate vs SSO) and isn't uniquely identifying
  /// without the local part. Strings without `@` are treated as a name.
  ///
  /// Examples: `john.doe@email.com` → `j**n.d*e@email.com`;
  /// `alice@example.com` → `a***e@example.com`; `j@gmail.com` →
  /// `*@gmail.com`.
  static String redactEmail(String email) {
    final atIndex = email.indexOf('@');
    if (atIndex < 0) return redactName(email);
    final local = email.substring(0, atIndex);
    final domain = email.substring(atIndex);
    // Empty segments (consecutive/leading/trailing dots) map to '' via
    // redactName's empty branch, preserving the local part's shape.
    final maskedLocal = local.split('.').map(redactName).join('.');
    return '$maskedLocal$domain';
  }

  /// Masks every email-shaped token embedded in [text] via [redactEmail].
  ///
  /// Used by the BreadcrumbBuffer to sanitise log messages: a forgotten
  /// `info('failed for $email')` can't leak a full address into a buffered
  /// breadcrumb. Returns [text] itself (same instance) when no email is
  /// present.
  static String redactEmailsIn(String text) {
    if (!_emailPattern.hasMatch(text)) return text;
    return text.replaceAllMapped(
      _emailPattern,
      (match) => redactEmail(match[0]!),
    );
  }

  /// Generic middle-mask: keeps [keepStart] leading and [keepEnd] trailing
  /// characters, masks the rest with [maskChar]. Inputs no longer than
  /// `keepStart + keepEnd` are fully masked — keeping both ends of a
  /// too-short value would reveal it entirely.
  ///
  /// Throws [ArgumentError] when [keepStart] or [keepEnd] is negative.
  /// Runtime checks rather than asserts: this is a public redaction
  /// utility, and in a release build (asserts stripped) a negative
  /// value would otherwise surface as a cryptic substring [RangeError]
  /// far from the bad call site.
  static String maskMiddle(
    String input, {
    int keepStart = 1,
    int keepEnd = 1,
    String maskChar = '*',
  }) {
    if (keepStart < 0) {
      throw ArgumentError.value(keepStart, 'keepStart', 'must be >= 0');
    }
    if (keepEnd < 0) {
      throw ArgumentError.value(keepEnd, 'keepEnd', 'must be >= 0');
    }
    if (input.length <= keepStart + keepEnd) {
      return maskChar * input.length;
    }
    final masked = maskChar * (input.length - keepStart - keepEnd);
    return '${input.substring(0, keepStart)}'
        '$masked'
        '${input.substring(input.length - keepEnd)}';
  }

  /// Caps [input] at [maxLength] total characters, replacing the overflow
  /// tail with [ellipsis]. Inputs within the cap are returned unchanged
  /// (same instance).
  ///
  /// Throws [ArgumentError] when [maxLength] can't fit [ellipsis] —
  /// runtime check rather than assert, for the same release-build
  /// rationale as [maskMiddle].
  static String truncate(String input, int maxLength, {String ellipsis = '…'}) {
    if (maxLength < ellipsis.length) {
      throw ArgumentError.value(
        maxLength,
        'maxLength',
        'must be >= the ellipsis length (${ellipsis.length})',
      );
    }
    if (input.length <= maxLength) return input;
    return '${input.substring(0, maxLength - ellipsis.length)}$ellipsis';
  }

  /// Returns a copy of [json] with every key in [fields] replaced by
  /// [replacement]. With [recursive] (the default), nested maps — including
  /// maps inside lists — are scrubbed too. Matching is exact and
  /// case-sensitive. The input map is never mutated.
  static Map<String, dynamic> redactJsonFields(
    Map<String, dynamic> json,
    Set<String> fields, {
    String replacement = defaultReplacement,
    bool recursive = true,
  }) {
    final out = <String, dynamic>{};
    json.forEach((key, value) {
      if (fields.contains(key)) {
        out[key] = replacement;
      } else {
        out[key] = recursive ? _redactValue(value, fields, replacement) : value;
      }
    });
    return out;
  }

  static dynamic _redactValue(
    dynamic value,
    Set<String> fields,
    String replacement,
  ) {
    if (value is Map<String, dynamic>) {
      return redactJsonFields(value, fields, replacement: replacement);
    }
    if (value is Map) {
      // Non-String-keyed maps shouldn't appear in JSON-shaped data, but
      // degrade gracefully by stringifying keys rather than throwing.
      return redactJsonFields(
        value.map((key, nested) => MapEntry(key.toString(), nested)),
        fields,
        replacement: replacement,
      );
    }
    if (value is List) {
      return value
          .map((element) => _redactValue(element, fields, replacement))
          .toList();
    }
    return value;
  }
}
