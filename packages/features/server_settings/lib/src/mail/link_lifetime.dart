import 'package:server_settings/l10n/server_settings_localizations.dart';

/// Reads a password reset link lifetime of [minutes] in days, hours and
/// minutes, largest first, naming only the parts that aren't zero: 1500 is
/// "1 day, 1 hour" (#807).
///
/// The field takes minutes, the server's unit, so a saved value comes back
/// exactly as entered. This is the plain-language reading beside it.
String describeLinkLifetime(int minutes, ServerSettingsLocalizations l10n) {
  final days = minutes ~/ Duration.minutesPerDay;
  final hours = minutes % Duration.minutesPerDay ~/ Duration.minutesPerHour;
  final rest = minutes % Duration.minutesPerHour;
  final parts = [
    if (days > 0) l10n.mailLifetimeDays(days),
    if (hours > 0) l10n.mailLifetimeHours(hours),
    if (rest > 0 || minutes == 0) l10n.mailLifetimeMinutes(rest),
  ];
  return parts.join(', ');
}
