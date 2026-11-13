import 'package:events/l10n/events_localizations.dart';

/// A game's name as the events screens show it (#851): its [title] alone
/// where [subtitle] is null or empty, otherwise both, as Collection's rows
/// name it ([EventsLocalizations.eventsOfferTitleWithSubtitle]), "Catan:
/// Seafarers". The subtitle is often what tells two games apart, so a row,
/// the controls that name its game, and an outcome about it all say it.
String gameName(EventsLocalizations l10n, String title, String? subtitle) =>
    subtitle == null || subtitle.isEmpty
    ? title
    : l10n.eventsOfferTitleWithSubtitle(title, subtitle);
