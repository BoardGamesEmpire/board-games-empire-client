import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:models/domain.dart';

import '../support/fake_household_invite_remote.dart';

void main() {
  final l10n = lookupHouseholdLocalizations(const Locale('en'));

  // A widget test gets the date formats from the Material delegates; a
  // plain test loads them itself.
  setUpAll(() => initializeDateFormatting('en'));

  test('the expiry line says Expired on an expired invite', () {
    expect(
      inviteExpiryLine(
        l10n,
        invite('i_1', status: HouseholdInviteStatus.expired),
      ),
      'Expired Oct 26, 2026',
    );
  });

  test('the expiry line says Expires on an outstanding invite', () {
    for (final status in const [
      HouseholdInviteStatus.pending,
      HouseholdInviteStatus.awaitingApproval,
    ]) {
      expect(
        inviteExpiryLine(l10n, invite('i_1', status: status)),
        'Expires Oct 26, 2026',
        reason: '$status',
      );
      expect(inviteSettledLabel(l10n, status), isNull, reason: '$status');
    }
  });

  test('a settled invite has no expiry line, and a label for its status', () {
    const labels = {
      HouseholdInviteStatus.accepted: 'Accepted',
      HouseholdInviteStatus.declined: 'Declined',
      HouseholdInviteStatus.withdrawn: 'Withdrawn',
      HouseholdInviteStatus.revoked: 'Revoked',
    };
    labels.forEach((status, label) {
      expect(
        inviteExpiryLine(l10n, invite('i_1', status: status)),
        isNull,
        reason: '$status',
      );
      expect(inviteSettledLabel(l10n, status), label, reason: '$status');
    });
  });

  test('an expired invite and one of a status this client does not know '
      'have no settled label', () {
    expect(inviteSettledLabel(l10n, HouseholdInviteStatus.expired), isNull);
    expect(
      inviteExpiryLine(
        l10n,
        invite('i_1', status: HouseholdInviteStatus.unknown),
      ),
      isNull,
    );
    expect(inviteSettledLabel(l10n, HouseholdInviteStatus.unknown), isNull);
  });
}
