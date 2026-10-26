import 'package:test/test.dart';
import 'package:models/domain.dart';

DateTime get _now => DateTime.parse('2024-01-15T10:30:00Z');

HouseholdMember _make({
  HouseholdRole? role,
  bool showAllGames = true,
  String? username,
  String? displayName,
  String? avatarUrl,
}) => HouseholdMember(
  id: 'hm_1',
  userId: 'user_1',
  householdId: 'h_1',
  role: role,
  showAllGames: showAllGames,
  username: username,
  displayName: displayName,
  avatarUrl: avatarUrl,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('HouseholdMember', () {
    test('defaults: showAllGames true, role null', () {
      final m = _make();
      expect(m.showAllGames, isTrue);
      expect(m.role, isNull);
    });

    group('isOwner', () {
      test('true only for HouseholdRole.householdOwner', () {
        expect(_make(role: HouseholdRole.householdOwner).isOwner, isTrue);
        expect(_make(role: HouseholdRole.householdAdmin).isOwner, isFalse);
        expect(_make(role: HouseholdRole.householdMember).isOwner, isFalse);
        expect(_make(role: HouseholdRole.householdGuest).isOwner, isFalse);
        expect(_make(role: HouseholdRole.unknown).isOwner, isFalse);
        expect(_make().isOwner, isFalse, reason: 'null role is not owner');
      });
    });

    group('isAdmin', () {
      test('true for owner or admin only', () {
        expect(_make(role: HouseholdRole.householdOwner).isAdmin, isTrue);
        expect(_make(role: HouseholdRole.householdAdmin).isAdmin, isTrue);
        expect(_make(role: HouseholdRole.householdMember).isAdmin, isFalse);
        expect(_make(role: HouseholdRole.householdGuest).isAdmin, isFalse);
        expect(_make(role: HouseholdRole.unknown).isAdmin, isFalse);
        expect(_make().isAdmin, isFalse);
      });
    });

    test('round-trips with role enum field', () {
      final m = _make(role: HouseholdRole.householdAdmin, showAllGames: false);
      final round = HouseholdMember.fromJson(m.toJson());
      expect(round, equals(m));
    });

    test('json contains showAllGames as boolean and role as PascalCase', () {
      final json = _make(role: HouseholdRole.householdOwner).toJson();
      expect(json['showAllGames'], isTrue);
      expect(json['role'], equals('HouseholdOwner'));
    });

    group("the member's name (#304)", () {
      test('name prefers the display name', () {
        expect(_make(username: 'alexd', displayName: 'Alex').name, 'Alex');
        expect(_make(username: 'alexd').name, 'alexd');
      });

      test('name is null for a member with no identity cached', () {
        expect(_make().name, isNull);
      });

      test('the names survive a JSON round trip', () {
        final m = _make(
          username: 'alexd',
          displayName: 'Alex',
          avatarUrl: 'https://x/a.png',
        );
        expect(HouseholdMember.fromJson(m.toJson()), equals(m));
      });
    });
  });
}
