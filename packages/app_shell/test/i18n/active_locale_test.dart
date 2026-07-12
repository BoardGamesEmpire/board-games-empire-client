import 'dart:ui';

import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';

/// Pins the #33 active-locale controller contract: it is the concrete
/// [ActiveLocaleReader] (BCP 47 tag of the held locale), a plain
/// [ValueNotifier] with dedupe semantics (assigning an equal Locale does
/// not notify), and synchronously disposable.
void main() {
  group('ActiveLocaleController', () {
    test('implements ActiveLocaleReader', () {
      final controller = ActiveLocaleController(const Locale('en'));
      addTearDown(controller.dispose);

      expect(controller, isA<ActiveLocaleReader>());
    });

    test('languageTag renders the held locale as a BCP 47 tag', () {
      final controller = ActiveLocaleController(const Locale('en', 'US'));
      addTearDown(controller.dispose);

      expect(controller.languageTag, 'en-US');

      controller.value = const Locale('de');
      expect(controller.languageTag, 'de');
    });

    test('notifies on a locale change', () {
      final controller = ActiveLocaleController(const Locale('en'));
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.value = const Locale('fr');

      expect(notifications, 1);
      expect(controller.value, const Locale('fr'));
    });

    test('assigning an equal locale does not notify (ValueNotifier '
        'dedupe — capture re-fires are free)', () {
      final controller = ActiveLocaleController(const Locale('en'));
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.value = const Locale('en');

      expect(notifications, 0);
    });
  });
}
