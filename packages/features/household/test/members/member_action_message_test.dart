import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:network_interface/network_interface.dart';

HouseholdMemberRefusedException _refused(int status) =>
    HouseholdMemberRefusedException('refused', statusCode: status);

void main() {
  final l10n = lookupHouseholdLocalizations(const Locale('en'));

  String message(
    HouseholdMemberAction action,
    HouseholdMemberActionResult result, [
    Object? error,
  ]) => memberActionMessage(
    l10n,
    HouseholdMemberOutcome(action: action, result: result, error: error),
  );

  const roleActions = [
    HouseholdMemberAction.changeRole,
    HouseholdMemberAction.makeOwner,
  ];

  group('memberActionMessage', () {
    test('a role change that was done', () {
      expect(
        message(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.done,
        ),
        'Role changed.',
      );
    });

    test('a removal that was done', () {
      expect(
        message(HouseholdMemberAction.remove, HouseholdMemberActionResult.done),
        'Removed from the household.',
      );
    });

    test('a removal of someone already gone', () {
      expect(
        message(
          HouseholdMemberAction.remove,
          HouseholdMemberActionResult.gone,
          _refused(404),
        ),
        'They had already left the household, or it no longer exists.',
      );
    });

    test('a role change for someone gone', () {
      expect(
        message(
          HouseholdMemberAction.changeRole,
          HouseholdMemberActionResult.gone,
          _refused(404),
        ),
        'That member is no longer in the household, or it no longer exists.',
      );
    });

    test("a 403 says the viewer's role may have changed", () {
      for (final action in HouseholdMemberAction.values) {
        expect(
          message(action, HouseholdMemberActionResult.refused, _refused(403)),
          "You can't do that here any more. Your role in this household may "
          'have changed.',
          reason: action.name,
        );
      }
    });

    test("a 400 or 409 says the server didn't accept it", () {
      for (final action in HouseholdMemberAction.values) {
        for (final status in [400, 409]) {
          expect(
            message(
              action,
              HouseholdMemberActionResult.refused,
              _refused(status),
            ),
            "The server didn't accept that change. The household is being "
            'read again.',
            reason: '${action.name} $status',
          );
        }
      }
    });

    test('a transient failure asks to try again', () {
      for (final action in HouseholdMemberAction.values) {
        expect(
          message(
            action,
            HouseholdMemberActionResult.failed,
            const HouseholdMemberTransientException('down'),
          ),
          "Couldn't reach the server. Try again.",
          reason: action.name,
        );
      }
    });

    test('a permanent failure, or any other error, is unexpected', () {
      const unexpected =
          'Something went wrong. The household is being read again to show '
          'where things stand.';
      for (final action in HouseholdMemberAction.values) {
        expect(
          message(
            action,
            HouseholdMemberActionResult.failed,
            const HouseholdMemberPermanentException('?', statusCode: 200),
          ),
          unexpected,
          reason: action.name,
        );
        expect(
          message(action, HouseholdMemberActionResult.failed, StateError('x')),
          unexpected,
          reason: action.name,
        );
      }
    });

    test('make-owner reads as a role change until it has its own (#478)', () {
      for (final action in roleActions) {
        expect(
          message(action, HouseholdMemberActionResult.done),
          'Role changed.',
          reason: action.name,
        );
        expect(
          message(action, HouseholdMemberActionResult.gone, _refused(404)),
          'That member is no longer in the household, or it no longer exists.',
          reason: action.name,
        );
      }
    });
  });
}
