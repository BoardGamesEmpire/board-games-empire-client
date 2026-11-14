import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('ProfilePatch', () {
    test('an empty patch is empty', () {
      expect(const ProfilePatch().isEmpty, isTrue);
    });

    group('any one field makes it non-empty', () {
      final patches = <String, ProfilePatch>{
        'displayName': const ProfilePatch(displayName: 'Ada'),
        'bio': const ProfilePatch(bio: SettingValue.set('Hi')),
        'bio cleared': const ProfilePatch(bio: SettingValue.clear()),
        'pronouns': const ProfilePatch(pronouns: SettingValue.set('she/her')),
        'location': const ProfilePatch(location: SettingValue.set('Leeds')),
        'houseRulesPreference': const ProfilePatch(
          houseRulesPreference: SettingValue.set('Strict'),
        ),
        'dietaryRestrictions': const ProfilePatch(
          dietaryRestrictions: SettingValue.set('Vegan'),
        ),
        'accessibilityNeeds': const ProfilePatch(
          accessibilityNeeds: SettingValue.set('Large print'),
        ),
        'preferredPlayerCount': const ProfilePatch(
          preferredPlayerCount: SettingValue.set(4),
        ),
        'preferredPlayerCount cleared': const ProfilePatch(
          preferredPlayerCount: SettingValue.clear(),
        ),
        'willingToTeach': const ProfilePatch(willingToTeach: false),
        'openToNewPlayers': const ProfilePatch(openToNewPlayers: false),
        'hostingCapability': const ProfilePatch(hostingCapability: false),
        'isSearchable': const ProfilePatch(isSearchable: false),
        'reach': const ProfilePatch(reach: Reach.private),
      };

      for (final entry in patches.entries) {
        test(entry.key, () => expect(entry.value.isEmpty, isFalse));
      }
    });

    test('two patches with the same changes are equal', () {
      const a = ProfilePatch(
        displayName: 'Ada',
        bio: SettingValue.clear(),
        preferredPlayerCount: SettingValue.set(4),
        reach: Reach.friends,
      );
      const b = ProfilePatch(
        displayName: 'Ada',
        bio: SettingValue.clear(),
        preferredPlayerCount: SettingValue.set(4),
        reach: Reach.friends,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const ProfilePatch(displayName: 'Ada')));
    });
  });
}
