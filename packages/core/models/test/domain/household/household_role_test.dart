import 'package:test/test.dart';
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

    group('fromWire', () {
      test('resolves every known role name', () {
        const expectations = <String, HouseholdRole>{
          'HouseholdOwner': HouseholdRole.householdOwner,
          'HouseholdAdmin': HouseholdRole.householdAdmin,
          'HouseholdMember': HouseholdRole.householdMember,
          'HouseholdGuest': HouseholdRole.householdGuest,
        };

        for (final entry in expectations.entries) {
          expect(HouseholdRole.fromWire(entry.key), equals(entry.value));
        }
      });

      test('agrees with the JsonValue annotations for every role', () {
        // fromWire's switch is a SECOND transcription of the wire names the
        // @JsonValue annotations already carry, and the generated enum map is
        // private, so nothing but this test ties the two together. Without
        // it, adding a role and forgetting the switch is silent: fromJson
        // resolves it, fromWire returns unknown, and isOwner/isAdmin go false
        // for every member holding it.
        for (final value in HouseholdRole.values) {
          if (value == HouseholdRole.unknown) continue;
          final wire = _makeMember(role: value).toJson()['role'] as String;
          expect(
            HouseholdRole.fromWire(wire),
            equals(value),
            reason:
                'fromWire("$wire") should resolve to HouseholdRole.${value.name} '
                '— its @JsonValue says that is its wire name',
          );
        }
      });

      test('degrades an unrecognized role name to unknown', () {
        // A server deployment is free to define its own roles; the client
        // degrades rather than throwing. This is the ONE thing `unknown` is
        // for, which is why the wire-shape adapter must never reach it by
        // handing this method something that is not a role name.
        expect(
          HouseholdRole.fromWire('SomeFutureCustomRole'),
          equals(HouseholdRole.unknown),
        );
      });

      test('never resolves to the sentinel name itself', () {
        // `unknown` is client-only and is never sent to the server, so the
        // string "unknown" is not a role name — it is just another
        // unrecognized one.
        expect(
          HouseholdRole.fromWire('unknown'),
          equals(HouseholdRole.unknown),
        );
      });
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
