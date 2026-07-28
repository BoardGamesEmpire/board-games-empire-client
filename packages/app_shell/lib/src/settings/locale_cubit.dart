import 'package:flutter/widgets.dart' show Locale;
import 'package:hydrated_bloc/hydrated_bloc.dart';

/// App-level, persisted locale *override* (#120 Q5) feeding
/// `MaterialApp.locale`.
///
/// `null` means "follow the system locale": with a null `MaterialApp.locale`
/// Flutter's resolution picks the best supported match for the device
/// locale, falling back to the first supported locale (English) when there
/// is no match. A non-null value is an explicit user override.
///
/// This is distinct from `ActiveLocaleController` (#33), which is a
/// read-only *mirror* of the negotiated locale and cannot drive selection;
/// the override set here flows into negotiation and the mirror reflects it.
///
/// [HydratedCubit] construction-timing caveat applies — see [ThemeModeCubit].
class LocaleCubit extends HydratedCubit<Locale?> {
  /// Seeds [initialLocale] (default `null` = follow system) — the value
  /// used until a stored selection is hydrated, and the fresh-install
  /// default. The embedder/`runBgeApp` value flows in here; a persisted
  /// user selection still overrides it.
  LocaleCubit({Locale? initialLocale}) : super(initialLocale);

  /// Records an explicit locale, or `null` to follow the system locale.
  void select(Locale? locale) => emit(locale);

  @override
  Locale? fromJson(Map<String, dynamic> json) {
    final tag = json['languageTag'];
    if (tag is! String || tag.isEmpty) return null;
    return _parseLanguageTag(tag);
  }

  @override
  Map<String, dynamic>? toJson(Locale? state) => {
    'languageTag': state?.toLanguageTag(),
  };

  /// Pragmatic BCP 47 parse covering the tags the app emits via
  /// [Locale.toLanguageTag]: `language`, optional 4-letter `script`, and
  /// optional 2-letter / 3-digit `region`, in either `-` or `_` form.
  ///
  /// Defensive against corrupt storage: returns null (follow system) for
  /// anything whose primary subtag is not a well-formed language code,
  /// rather than letting [Locale.fromSubtags] assert on an empty subtag or
  /// mint an invalid locale — matching [ThemeModeCubit]'s unknown-value
  /// fallback. (We only ever emit 2–3 letter language codes, so the rarer
  /// reserved/registered forms are treated as corrupt here.)
  static Locale? _parseLanguageTag(String tag) {
    final parts = tag.split(RegExp('[-_]'));
    final language = parts.first.toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language)) return null;
    String? script;
    String? region;
    for (final part in parts.skip(1)) {
      if (RegExp(r'^[A-Za-z]{4}$').hasMatch(part)) {
        script = part[0].toUpperCase() + part.substring(1).toLowerCase();
      } else if (RegExp(r'^[A-Za-z]{2}$').hasMatch(part) ||
          RegExp(r'^[0-9]{3}$').hasMatch(part)) {
        region = part.toUpperCase();
      }
    }
    return Locale.fromSubtags(
      languageCode: language,
      scriptCode: script,
      countryCode: region,
    );
  }
}
