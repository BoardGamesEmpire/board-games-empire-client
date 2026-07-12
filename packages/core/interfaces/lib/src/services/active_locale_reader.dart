/// The application's active (negotiated) locale (#33).
///
/// This is the locale the UI actually renders in — the result of
/// Flutter's resolution of the OS-preferred locales against the app's
/// `supportedLocales` — **not** the raw OS locale, which may name a
/// language the app has no translations for. Consumers (gateway `locale`
/// hints for search/import, feedback-report environment stamps) depend
/// only on this read surface.
///
/// Per ISP the interface is read-only and Flutter-free: no `Locale`
/// type (this package is pure Dart), no change stream — every current
/// consumer reads the value lazily at use time (per request / per
/// report), so a getter is the whole contract. A watch surface can be
/// added when a consumer genuinely needs push semantics.
///
/// The concrete implementation (`ActiveLocaleController`) lives in
/// `packages/app_shell`: the negotiated locale is only knowable inside
/// the running `MaterialApp`, so the shell captures it below
/// `Localizations` and mirrors it here. It is registered app-scope in
/// the root container; before the first frame it holds the raw OS
/// locale as a best-effort seed.
abstract interface class ActiveLocaleReader {
  /// The active locale as a BCP 47 language tag (e.g. `en`, `de-DE`).
  String get languageTag;
}
