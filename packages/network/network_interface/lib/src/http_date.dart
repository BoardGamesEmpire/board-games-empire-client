/// Matches RFC 9110 §5.6.7 IMF-fixdate, the mandatory `Date` format
/// modern servers emit: `Sun, 06 Nov 1994 08:49:37 GMT`.
final RegExp _imfFixdate = RegExp(
  r'^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), '
  r'(\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) '
  r'(\d{2}):(\d{2}):(\d{2}) GMT$',
);

const Map<String, int> _months = {
  'Jan': 1,
  'Feb': 2,
  'Mar': 3,
  'Apr': 4,
  'May': 5,
  'Jun': 6,
  'Jul': 7,
  'Aug': 8,
  'Sep': 9,
  'Oct': 10,
  'Nov': 11,
  'Dec': 12,
};

/// Parses an HTTP `Date` header value, returning `null` on anything
/// that is not a valid IMF-fixdate (#12, #118).
///
/// Pure Dart on purpose: `dart:io`'s `HttpDate` cannot compile for web,
/// and this package is the shared home for both the native
/// (`dio_network`) and web (`web_network`) stacks — the clock-skew
/// pipeline treats an unparsable header as "no sample", a fully
/// supported state, so a `null`-returning parser needs no exceptions
/// at all.
///
/// Deliberate strictness and leniencies:
///
/// - Only the RFC 9110 preferred IMF-fixdate form is accepted; the
///   obsolete RFC 850 (`Sunday, 06-Nov-94 08:49:37 GMT`) and asctime
///   (`Sun Nov  6 08:49:37 1994`) forms return `null`. A general HTTP
///   client must accept them; an opportunistic calibration sampler
///   loses nothing by skipping relics.
/// - Field names are case-sensitive per the RFC grammar.
/// - Calendar and clock validity is enforced by echo-checking every
///   field after `DateTime.utc` construction, which otherwise silently
///   normalizes nonsense (`32 Jan` → `1 Feb`, `24:00` → next day).
///   This also rejects the leap-second `:60` — one lost sample per
///   leap second is noise.
/// - The day-of-week name is **not** validated against the date: a
///   server with a wrong weekday still communicates an unambiguous
///   instant, which is all the skew estimator needs.
///
/// Returns a UTC [DateTime] with one-second resolution.
DateTime? tryParseHttpDate(String value) {
  final match = _imfFixdate.firstMatch(value.trim());
  if (match == null) return null;

  final day = int.parse(match[1]!);
  final month = _months[match[2]!]!;
  final year = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);

  final parsed = DateTime.utc(year, month, day, hour, minute, second);
  final normalized =
      parsed.year != year ||
      parsed.month != month ||
      parsed.day != day ||
      parsed.hour != hour ||
      parsed.minute != minute ||
      parsed.second != second;
  return normalized ? null : parsed;
}
