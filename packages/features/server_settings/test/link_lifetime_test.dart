import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:server_settings/l10n/server_settings_localizations.dart';
import 'package:server_settings/src/mail/link_lifetime.dart';

void main() {
  final l10n = lookupServerSettingsLocalizations(const Locale('en'));

  group('describeLinkLifetime', () {
    for (final (minutes, reading) in [
      (1440, '1 day'),
      (90, '1 hour, 30 minutes'),
      (10080, '7 days'),
      (1500, '1 day, 1 hour'),
    ]) {
      test('reads $minutes minutes as "$reading"', () {
        expect(describeLinkLifetime(minutes, l10n), reading);
      });
    }

    test('names every non-zero part, largest first', () {
      expect(
        describeLinkLifetime(2 * 1440 + 3 * 60 + 15, l10n),
        '2 days, 3 hours, 15 minutes',
      );
    });

    test('reads the shortest lifetime in minutes alone', () {
      expect(describeLinkLifetime(15, l10n), '15 minutes');
    });
  });
}
