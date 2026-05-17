import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

HouseholdMember _makeMember({HouseholdRole? role}) {
  final now = DateTime.parse('2024-01-15T10:30:00Z');
  return HouseholdMember(
    id: 'hm_1',
    userId: 'user_1',
    householdId: 'h_1',
    role: role,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('HouseholdRole', () {
    test('every known Dart value round-trips through HouseholdMember', () {
      for (final value in HouseholdRole.values) {
        if (value == HouseholdRole.unknown) continue;
        final member = _makeMember(role: value);
        final round = HouseholdMember.fromJson(member.toJson());
        expect(
          round.role,
          equals(value),
          reason: 'HouseholdRole.${value.name} should round-trip',
        );
      }
    });

    test('wire format is PascalCase for known roles', () {
      const expectations = <HouseholdRole, String>{
        HouseholdRole.householdOwner: 'HouseholdOwner',
        HouseholdRole.householdAdmin: 'HouseholdAdmin',
        HouseholdRole.householdMember: 'HouseholdMember',
        HouseholdRole.householdGuest: 'HouseholdGuest',
      };

      for (final entry in expectations.entries) {
        expect(
          _makeMember(role: entry.key).toJson()['role'],
          equals(entry.value),
          reason:
              'HouseholdRole.${entry.key.name} should serialize as "${entry.value}"',
        );
      }
    });

    test('unknown server role name deserializes to HouseholdRole.unknown', () {
      final json = _makeMember(role: HouseholdRole.householdMember).toJson();
      json['role'] = 'SomeFutureCustomRole';

      final member = HouseholdMember.fromJson(json);
      expect(member.role, equals(HouseholdRole.unknown));
    });

    test('null role survives a JSON round-trip', () {
      final member = _makeMember();
      final round = HouseholdMember.fromJson(member.toJson());
      expect(round.role, isNull);
    });

    test('every household-prefixed Prisma SystemRole has a Dart binding', () {
      // Subset of prisma/models/permissions/role.prisma SystemRole enum.
      const serverValues = <String>[
        'HouseholdOwner',
        'HouseholdAdmin',
        'HouseholdMember',
        'HouseholdGuest',
      ];

      for (final wireValue in serverValues) {
        final json = _makeMember(role: HouseholdRole.householdMember).toJson();
        json['role'] = wireValue;
        expect(
          () => HouseholdMember.fromJson(json),
          returnsNormally,
          reason: 'server value "$wireValue" must deserialize',
        );
      }
    });
  });
}
