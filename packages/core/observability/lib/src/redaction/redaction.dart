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

  // The two landmarks of a failed statement's error text, as sqlite3 writes it.
  static const String _statementMarker = 'Causing statement';
  static const String _parametersMarker = ', parameters: ';

  // The two landmarks of drift's isolate channel refusing a request, as
  // `ExecuteQuery.toString()` writes it: `<method>: <sql> with [<values>]`.
  static const String _requestMarker = 'Tried to send Request';
  static const String _valuesMarker = ' with [';
  static const String _closedConnection =
      ' over isolate channel, but the connection was closed!';

  // A request that bound nothing: an empty list, the transaction id drift adds
  // inside a transaction, then the fixed reason as the end of the text. Strings
  // in the list are unquoted, so ` with []` alone can start a value such as
  // `]x`. A value that repeats the reason still fails this, because the list's
  // own closing bracket and reason come after it.
  static final RegExp _unboundRequest = RegExp(
    ' with \\[\\](?: \\(@\\d+\\))?${RegExp.escape(_closedConnection)}\$',
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

  /// Removes the values a failed database statement was bound to from the
  /// error [text] that reports it (#463).
  ///
  /// Two shapes carry them. `SqliteException.toString()` writes the
  /// statement, then `, parameters: ` and the bound values, as the last thing
  /// in the text, and drift's `DriftRemoteException` (what a background-isolate
  /// database throws) returns that same text, so the original type is not
  /// there to check. A statement sent after the connection closed never
  /// reaches sqlite: drift's isolate channel throws a `StateError` instead,
  /// with no `Causing statement` and no `, parameters: `, and the values
  /// follow `with`:
  ///
  /// ```
  /// Tried to send Request (id = 3): StatementMethod.insert: INSERT INTO t
  /// (a, b) VALUES (?, ?) with [user-42, Kitchen Table] over isolate channel,
  /// but the connection was closed!
  /// ```
  ///
  /// The values can be a user id or what the user wrote. The statement has
  /// placeholders only, so it stays. `PRAGMA key` is the one statement that
  /// interpolates a secret, and it keeps itself out of its own exception
  /// instead (`EncryptedExecutorFactory`).
  ///
  /// For the first shape, returns [text] up to the first `, parameters: `
  /// that follows the `Causing statement` marker, then `, parameters: `
  /// and the replacement. For the second, returns [text] up to the first
  /// ` with [` that follows `Tried to send Request`, then ` with ` and the
  /// replacement, then drift's fixed reason for the failure when it follows.
  /// The replacement is [defaultReplacement]. Anything else after the cut is
  /// dropped, which covers a second error a wrapper appended and keeps the
  /// failure on the safe side. When both shapes appear, the earlier cut wins,
  /// so nothing bound survives. Returns [text] itself (same instance) when it
  /// matches neither shape or is a request that bound nothing: an empty list
  /// followed only by drift's reason. An empty list followed by anything else
  /// can't be told from values that start with `]`, so it is cut too.
  ///
  /// This relies on the formats `sqlite3` and `drift` write today; tests in
  /// `drift_storage` run a real failing statement, and a real statement on a
  /// closed connection, to catch either changing.
  static String stripBoundValues(String text) {
    final sqlite = _cutAfter(text, _statementMarker, _parametersMarker);
    final channel = _firstValuesList(text);
    if (sqlite < 0 && channel < 0) return text;
    if (channel < 0 || (sqlite >= 0 && sqlite < channel)) {
      return '${text.substring(0, sqlite)}'
          '$_parametersMarker$defaultReplacement';
    }
    final reason = text.contains(_closedConnection, channel)
        ? _closedConnection
        : '';
    return '${text.substring(0, channel)} with $defaultReplacement$reason';
  }

  /// [error] itself, or its text without the bound values when it has any, for
  /// a sink or presenter that keeps the object where it can.
  ///
  /// Compares by value: text already stripped comes back equal but rebuilt,
  /// and has nothing left to remove.
  static Object scrubBoundValues(Object error) {
    final text = error.toString();
    final stripped = stripBoundValues(text);
    return stripped == text ? error : stripped;
  }

  /// The index of the first ` with [` after `Tried to send Request`, or -1
  /// when there is none or it belongs to a request that bound nothing.
  static int _firstValuesList(String text) {
    final index = _cutAfter(text, _requestMarker, _valuesMarker);
    if (index < 0 || _unboundRequest.matchAsPrefix(text, index) != null) {
      return -1;
    }
    return index;
  }

  /// The index of the first [landmark] at or after the first [marker] in
  /// [text], or -1 when either is missing.
  static int _cutAfter(String text, String marker, String landmark) {
    final start = text.indexOf(marker);
    if (start < 0) return -1;
    return text.indexOf(landmark, start);
  }

  /// Generic middle-mask: keeps [keepStart] leading and [keepEnd] trailing
  /// characters, masks the rest with [maskChar]. Inputs no longer than
  /// `keepStart + keepEnd` are fully masked — keeping both ends of a
  /// too-short value would reveal it entirely.
  ///
  /// Throws [ArgumentError] when [keepStart] or [keepEnd] is negative,
  /// or when [maskChar] is empty (an empty mask would leave the input
  /// effectively unmasked). Runtime checks rather than asserts: this is
  /// a public redaction utility, and in a release build (asserts
  /// stripped) a bad argument would otherwise surface as a cryptic
  /// downstream error — or, in the case of an empty mask, silently leak.
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
    if (maskChar.isEmpty) {
      throw ArgumentError.value(maskChar, 'maskChar', 'must not be empty');
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
