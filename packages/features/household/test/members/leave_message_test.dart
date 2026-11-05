import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:network_interface/network_interface.dart';

HouseholdMemberRefusedException _refused(int status) =>
    HouseholdMemberRefusedException('refused', statusCode: status);

void main() {
  final l10n = lookupHouseholdLocalizations(const Locale('en'));

  String message(HouseholdMemberActionResult result, Object? error) =>
      leaveFailureMessage(l10n, (result: result, error: error));

  group('leaveFailureMessage', () {
    test('an enveloped 404 says the person is no longer in it', () {
      expect(
        message(HouseholdMemberActionResult.gone, _refused(404)),
        "You're no longer in this household. It's being read again.",
      );
    });

    test('a 400 is the last owner', () {
      expect(
        message(HouseholdMemberActionResult.refused, _refused(400)),
        "You're the household's only owner. Make another member the owner "
        'first.',
      );
    });

    test('another refusal is a change the server did not accept', () {
      for (final status in [403, 409]) {
        expect(
          message(HouseholdMemberActionResult.refused, _refused(status)),
          "The server didn't accept that change. The household is being "
          'read again.',
          reason: '$status',
        );
      }
    });

    test('no answer says the server could not be reached', () {
      expect(
        message(
          HouseholdMemberActionResult.failed,
          const HouseholdMemberTransientException('down'),
        ),
        "Couldn't reach the server. Try again.",
      );
    });

    test('anything else is unexpected', () {
      expect(
        message(
          HouseholdMemberActionResult.failed,
          const HouseholdMemberPermanentException('bad body'),
        ),
        'Something went wrong. The household is being read again to show '
        'where things stand.',
      );
      expect(
        message(HouseholdMemberActionResult.failed, StateError('boom')),
        'Something went wrong. The household is being read again to show '
        'where things stand.',
      );
    });

    test("never shows the server's own message", () {
      // backend#822: the body's message is translated by the server, and
      // may not be in the app's language.
      const secret = 'Le serveur dit non';
      for (final (result, error) in [
        (
          HouseholdMemberActionResult.gone,
          const HouseholdMemberRefusedException(secret, statusCode: 404),
        ),
        (
          HouseholdMemberActionResult.refused,
          const HouseholdMemberRefusedException(secret, statusCode: 400),
        ),
        (
          HouseholdMemberActionResult.failed,
          const HouseholdMemberTransientException(secret),
        ),
      ]) {
        expect(message(result, error), isNot(contains(secret)));
      }
    });
  });
}
