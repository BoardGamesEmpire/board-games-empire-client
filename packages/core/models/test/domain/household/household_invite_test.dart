import 'package:models/domain.dart';
import 'package:test/test.dart';

HouseholdInvite _invite({String? inviteeName, String? inviteeEmail}) =>
    HouseholdInvite(
      id: 'i_1',
      status: HouseholdInviteStatus.pending,
      inviter: const UserSummary(id: 'u_1', username: 'ana'),
      inviteeName: inviteeName,
      inviteeEmail: inviteeEmail,
      expiresAt: DateTime.utc(2026, 10, 26),
      createdAt: DateTime.utc(2026, 10, 19),
    );

void main() {
  const wire = {
    'Pending': HouseholdInviteStatus.pending,
    'AwaitingApproval': HouseholdInviteStatus.awaitingApproval,
    'Accepted': HouseholdInviteStatus.accepted,
    'Declined': HouseholdInviteStatus.declined,
    'Expired': HouseholdInviteStatus.expired,
    'Revoked': HouseholdInviteStatus.revoked,
    'Withdrawn': HouseholdInviteStatus.withdrawn,
  };

  group('HouseholdInviteStatus', () {
    test('fromWire maps every server status', () {
      for (final MapEntry(:key, :value) in wire.entries) {
        expect(HouseholdInviteStatus.fromWire(key), value, reason: key);
      }
    });

    test('fromWire degrades a name it does not know to unknown', () {
      expect(
        HouseholdInviteStatus.fromWire('Bogus'),
        HouseholdInviteStatus.unknown,
      );
    });

    test('toWire round-trips every server status', () {
      for (final MapEntry(:key, :value) in wire.entries) {
        expect(value.toWire(), key);
      }
    });

    test('toWire refuses unknown, which the server never sent', () {
      expect(HouseholdInviteStatus.unknown.toWire, throwsStateError);
    });

    test('only pending and awaiting approval are outstanding', () {
      final outstanding = HouseholdInviteStatus.values
          .where((s) => s.isOutstanding)
          .toSet();
      expect(outstanding, {
        HouseholdInviteStatus.pending,
        HouseholdInviteStatus.awaitingApproval,
      });
    });
  });

  group('HouseholdInvite.inviteeLabel', () {
    test('prefers the name the inviter gave over the address', () {
      expect(
        _invite(inviteeName: 'Ana', inviteeEmail: 'a@b.c').inviteeLabel,
        'Ana',
      );
    });

    test('falls back to the address', () {
      expect(_invite(inviteeEmail: 'a@b.c').inviteeLabel, 'a@b.c');
    });

    test('is null when the row carries neither', () {
      expect(_invite().inviteeLabel, isNull);
    });
  });

  group('UserSummary.label', () {
    test('prefers the display name', () {
      expect(
        const UserSummary(
          id: 'u_1',
          username: 'ana',
          displayName: 'Ana B',
        ).label,
        'Ana B',
      );
    });

    test('falls back to the username', () {
      expect(const UserSummary(id: 'u_1', username: 'ana').label, 'ana');
    });
  });
}
