import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/game_name.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A game's name as the events screens show it (#851).
void main() {
  final l10n = lookupEventsLocalizations(const Locale('en'));

  test('names the title and the subtitle', () {
    expect(gameName(l10n, 'Catan', 'Seafarers'), 'Catan: Seafarers');
  });

  test('a null or empty subtitle gives the title alone', () {
    expect(gameName(l10n, 'Catan', null), 'Catan');
    expect(gameName(l10n, 'Catan', ''), 'Catan');
  });
}
