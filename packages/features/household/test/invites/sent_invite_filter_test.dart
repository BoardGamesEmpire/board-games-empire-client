import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';

import '../support/fake_household_invite_remote.dart';

void main() {
  test('open and expired asks for no status, and every other filter for its '
      'own', () {
    expect(SentInviteFilter.openAndExpired.status, isNull);
    for (final f in SentInviteFilter.values.where(
      (f) => f != SentInviteFilter.openAndExpired,
    )) {
      expect(f.status!.name, f.name);
    }
  });

  test('open and expired admits pending, awaiting and expired rows only', () {
    const admitted = {
      HouseholdInviteStatus.pending,
      HouseholdInviteStatus.awaitingApproval,
      HouseholdInviteStatus.expired,
    };
    for (final status in HouseholdInviteStatus.values) {
      expect(
        SentInviteFilter.openAndExpired.admits(invite('i', status: status)),
        admitted.contains(status),
        reason: '$status',
      );
    }
  });

  test('a status filter admits only its status', () {
    expect(
      SentInviteFilter.pending.admits(
        invite('i', status: HouseholdInviteStatus.withdrawn),
      ),
      isFalse,
    );
    expect(
      SentInviteFilter.withdrawn.admits(
        invite('i', status: HouseholdInviteStatus.withdrawn),
      ),
      isTrue,
    );
  });
}
