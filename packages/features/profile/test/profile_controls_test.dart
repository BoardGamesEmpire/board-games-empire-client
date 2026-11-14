import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:profile/src/form/profile_controls.dart';

import 'support/fake_user_profile_remote.dart';

/// A profile with every field set, so each can be changed or cleared.
final UserProfile _full = profileFixture(
  bio: 'Board games and tea.',
  pronouns: 'she/her',
  location: 'Leeds',
  preferredPlayerCount: 4,
  houseRulesPreference: 'No kingmaking',
  dietaryRestrictions: 'Vegetarian',
  accessibilityNeeds: 'Step-free access',
  willingToTeach: true,
);

/// [profile]'s values with [changes] laid over them.
Map<String, Object?> _valuesWith(
  UserProfile profile, [
  Map<String, Object?> changes = const {},
]) => {...profileValuesOf(profile), ...changes};

const _emoji = '\u{1F600}';

void main() {
  group('profilePatchOf', () {
    test('no change gives an empty patch', () {
      for (final profile in [
        _full,
        profileFixture(displayName: null, reach: null, isSearchable: null),
      ]) {
        expect(
          profilePatchOf(profile, profileValuesOf(profile)).isEmpty,
          isTrue,
          reason: '$profile',
        );
      }
    });

    test('a changed text field is set, trimmed', () {
      expect(
        profilePatchOf(
          _full,
          _valuesWith(_full, {
            ProfileControls.displayName: '  Ada L.  ',
            ProfileControls.pronouns: ' they/them ',
            ProfileControls.location: '\tYork\n',
            ProfileControls.houseRules: ' Any ',
            ProfileControls.dietaryRestrictions: ' Vegan ',
            ProfileControls.accessibilityNeeds: ' Large print ',
          }),
        ),
        const ProfilePatch(
          displayName: 'Ada L.',
          pronouns: SettingValue.set('they/them'),
          location: SettingValue.set('York'),
          houseRulesPreference: SettingValue.set('Any'),
          dietaryRestrictions: SettingValue.set('Vegan'),
          accessibilityNeeds: SettingValue.set('Large print'),
        ),
      );
    });

    test("the bio is sent as typed: its leading spaces are Markdown's", () {
      const bio = '    an indented code block\n\nand a paragraph  ';

      expect(
        profilePatchOf(_full, _valuesWith(_full, {ProfileControls.bio: bio})),
        const ProfilePatch(bio: SettingValue.set(bio)),
      );
    });

    test('a cleared text field is clear', () {
      for (final blank in ['', '   ']) {
        expect(
          profilePatchOf(
            _full,
            _valuesWith(_full, {
              ProfileControls.bio: blank,
              ProfileControls.pronouns: blank,
              ProfileControls.location: blank,
              ProfileControls.houseRules: blank,
              ProfileControls.dietaryRestrictions: blank,
              ProfileControls.accessibilityNeeds: blank,
            }),
          ),
          const ProfilePatch(
            bio: SettingValue.clear(),
            pronouns: SettingValue.clear(),
            location: SettingValue.clear(),
            houseRulesPreference: SettingValue.clear(),
            dietaryRestrictions: SettingValue.clear(),
            accessibilityNeeds: SettingValue.clear(),
          ),
          reason: '"$blank"',
        );
      }
    });

    test('a blank field that was never set is no change', () {
      final empty = profileFixture();

      expect(
        profilePatchOf(
          empty,
          _valuesWith(empty, {
            ProfileControls.bio: '  \n ',
            ProfileControls.pronouns: '  ',
            ProfileControls.houseRules: ' ',
          }),
        ).isEmpty,
        isTrue,
      );
    });

    test('a field put back as it was leaves the patch empty', () {
      expect(
        profilePatchOf(
          _full,
          _valuesWith(_full, {
            ProfileControls.displayName: ' Ada ',
            ProfileControls.pronouns: 'she/her  ',
            ProfileControls.bio: 'Board games and tea.',
            ProfileControls.preferredPlayerCount: ' 4 ',
          }),
        ).isEmpty,
        isTrue,
      );
    });

    test('a stored value with padding, left alone, is no change', () {
      final padded = profileFixture(pronouns: ' she/her ');

      expect(
        profilePatchOf(padded, profileValuesOf(padded)).isEmpty,
        isTrue,
      );
    });

    test('a cleared player count is clear, a new one is set', () {
      expect(
        profilePatchOf(
          _full,
          _valuesWith(_full, {ProfileControls.preferredPlayerCount: ''}),
        ),
        const ProfilePatch(preferredPlayerCount: SettingValue.clear()),
      );
      expect(
        profilePatchOf(
          _full,
          _valuesWith(_full, {ProfileControls.preferredPlayerCount: ' 6 '}),
        ),
        const ProfilePatch(preferredPlayerCount: SettingValue.set(6)),
      );
      final none = profileFixture();
      expect(
        profilePatchOf(
          none,
          _valuesWith(none, {ProfileControls.preferredPlayerCount: '  '}),
        ).isEmpty,
        isTrue,
      );
    });

    test('reach and the switches are sent only when changed', () {
      expect(
        profilePatchOf(
          _full,
          _valuesWith(_full, {
            ProfileControls.willingToTeach: false,
            ProfileControls.openToNewPlayers: true,
            ProfileControls.hostingCapability: true,
            ProfileControls.isSearchable: false,
            ProfileControls.reach: Reach.extendedNetwork,
          }),
        ),
        const ProfilePatch(
          willingToTeach: false,
          openToNewPlayers: true,
          hostingCapability: true,
          isSearchable: false,
          reach: Reach.extendedNetwork,
        ),
      );
      expect(
        profilePatchOf(
          _full,
          _valuesWith(_full, {
            ProfileControls.willingToTeach: true,
            ProfileControls.reach: Reach.friends,
          }),
        ).isEmpty,
        isTrue,
      );
    });

    test(
      'a reach this app does not know shows no choice and is never sent',
      () {
        final unknown = profileFixture(reach: Reach.unknown);

        expect(profileValuesOf(unknown)[ProfileControls.reach], isNull);
        expect(
          profileValuesOf(profileFixture(reach: null)),
          containsPair(
            ProfileControls.reach,
            null,
          ),
        );
        expect(
          profilePatchOf(unknown, profileValuesOf(unknown)).isEmpty,
          isTrue,
        );
        expect(
          profilePatchOf(
            _full,
            _valuesWith(_full, {ProfileControls.reach: Reach.unknown}),
          ).isEmpty,
          isTrue,
        );
        expect(
          profilePatchOf(
            unknown,
            _valuesWith(unknown, {ProfileControls.reach: Reach.public}),
          ),
          const ProfilePatch(reach: Reach.public),
        );
      },
    );
  });

  group('profileHasChanges', () {
    test('follows the patch', () {
      expect(profileHasChanges(_full, profileValuesOf(_full)), isFalse);
      expect(
        profileHasChanges(
          _full,
          _valuesWith(_full, {ProfileControls.location: 'York'}),
        ),
        isTrue,
      );
    });

    test('counts a player count that is not a number, which the patch '
        'cannot carry', () {
      expect(
        profileHasChanges(
          _full,
          _valuesWith(_full, {ProfileControls.preferredPlayerCount: '4x'}),
        ),
        isTrue,
      );
    });
  });

  group('the form group', () {
    test("an untouched blank display name doesn't block saving the bio", () {
      final nameless = profileFixture(displayName: null);
      final form = profileFormGroup(() => nameless);

      form.control(ProfileControls.bio).value = 'Hello';

      expect(form.valid, isTrue);
      expect(
        profilePatchOf(nameless, form.value),
        const ProfilePatch(bio: SettingValue.set('Hello')),
      );
      form.dispose();
    });

    test('the display name refuses blank once changed', () {
      final form = profileFormGroup(() => _full);
      final name = form.control(ProfileControls.displayName);

      for (final blank in ['', '   ']) {
        name.value = blank;
        expect(name.hasError(ProfileErrors.blank), isTrue, reason: '"$blank"');
      }
      name.value = ' Ada ';
      expect(name.valid, isTrue);
      form.dispose();
    });

    test('the display name rule reads the profile as it is now', () {
      var initial = _full;
      final form = profileFormGroup(() => initial);
      final name = form.control(ProfileControls.displayName);

      initial = profileFixture(displayName: null);
      name.value = '';

      expect(name.valid, isTrue);
      form.dispose();
    });

    for (final (field, cap) in [
      (
        ProfileControls.displayName,
        UserProfileRemoteDataSource.maxDisplayNameLength,
      ),
      (ProfileControls.bio, UserProfileRemoteDataSource.maxBioLength),
      (ProfileControls.pronouns, UserProfileRemoteDataSource.maxPronounsLength),
      (ProfileControls.location, UserProfileRemoteDataSource.maxLocationLength),
      (
        ProfileControls.houseRules,
        UserProfileRemoteDataSource.maxHouseRulesLength,
      ),
      (
        ProfileControls.dietaryRestrictions,
        UserProfileRemoteDataSource.maxPracticalInfoLength,
      ),
      (
        ProfileControls.accessibilityNeeds,
        UserProfileRemoteDataSource.maxPracticalInfoLength,
      ),
    ]) {
      test("the $field cap counts the server's way", () {
        final form = profileFormGroup(() => _full);
        final control = form.control(field)..value = _emoji * cap;

        expect((control.value! as String).length, cap * 2);
        expect(control.valid, isTrue, reason: '$cap emoji');

        control.value = _emoji * (cap + 1);
        expect(control.hasError(ProfileErrors.tooLong), isTrue);
        form.dispose();
      });
    }

    test("a stored value past its cap, left alone, doesn't block saving "
        'another field', () {
      // The server can hand back more than it takes: a sanitized bio's
      // escapes can make it longer than what was typed.
      final over = profileFixture(
        displayName:
            'a' * (UserProfileRemoteDataSource.maxDisplayNameLength + 1),
        bio: _emoji * (UserProfileRemoteDataSource.maxBioLength + 1),
        pronouns: 'a' * (UserProfileRemoteDataSource.maxPronounsLength + 1),
        location: 'a' * (UserProfileRemoteDataSource.maxLocationLength + 1),
        houseRulesPreference:
            'a' * (UserProfileRemoteDataSource.maxHouseRulesLength + 1),
        dietaryRestrictions:
            'a' * (UserProfileRemoteDataSource.maxPracticalInfoLength + 1),
        accessibilityNeeds:
            'a' * (UserProfileRemoteDataSource.maxPracticalInfoLength + 1),
        preferredPlayerCount: UserProfileRemoteDataSource.maxPlayerCount + 1,
      );
      final form = profileFormGroup(() => over);
      expect(form.valid, isTrue);

      form.control(ProfileControls.isSearchable).value = false;

      expect(form.valid, isTrue);
      expect(
        profilePatchOf(over, form.value),
        const ProfilePatch(isSearchable: false),
      );
      form.dispose();
    });

    test('a stored value past its cap is refused once edited, still past '
        'it', () {
      final over = profileFixture(
        bio: _emoji * (UserProfileRemoteDataSource.maxBioLength + 1),
        pronouns: 'a' * (UserProfileRemoteDataSource.maxPronounsLength + 1),
        preferredPlayerCount: UserProfileRemoteDataSource.maxPlayerCount + 1,
      );
      final form = profileFormGroup(() => over);
      final bio = form.control(ProfileControls.bio)..value = '${over.bio}!';
      final pronouns = form.control(ProfileControls.pronouns)
        ..value = 'b${over.pronouns}';
      final count = form.control(ProfileControls.preferredPlayerCount)
        ..value = '${UserProfileRemoteDataSource.maxPlayerCount + 2}';

      expect(bio.hasError(ProfileErrors.tooLong), isTrue);
      expect(pronouns.hasError(ProfileErrors.tooLong), isTrue);
      expect(count.hasError(ProfileErrors.playerCount), isTrue);
      form.dispose();
    });

    test('a cleared field is never too long: clearing sends no text', () {
      final form = profileFormGroup(() => _full);
      final blank = ' ' * (UserProfileRemoteDataSource.maxBioLength + 1);
      final bio = form.control(ProfileControls.bio)..value = blank;
      final pronouns = form.control(ProfileControls.pronouns)..value = blank;

      expect(bio.valid, isTrue);
      expect(pronouns.valid, isTrue);
      expect(
        profilePatchOf(_full, form.value),
        const ProfilePatch(
          bio: SettingValue.clear(),
          pronouns: SettingValue.clear(),
        ),
      );
      form.dispose();
    });

    test('the cap checks read the profile as it is now', () {
      var initial = profileFixture(
        bio: _emoji * (UserProfileRemoteDataSource.maxBioLength + 1),
      );
      final form = profileFormGroup(() => initial);
      final bio = form.control(ProfileControls.bio);
      expect(bio.valid, isTrue);

      initial = _full;
      bio.updateValueAndValidity();

      expect(bio.hasError(ProfileErrors.tooLong), isTrue);
      form.dispose();
    });

    test('the trimmed fields are measured once trimmed', () {
      final form = profileFormGroup(() => _full);
      final pronouns = form.control(
        ProfileControls.pronouns,
      )..value = '   ${'a' * UserProfileRemoteDataSource.maxPronounsLength}   ';

      expect(pronouns.valid, isTrue);
      form.dispose();
    });

    test('the bio is measured as typed, its spaces included', () {
      final form = profileFormGroup(() => _full);
      final bio = form.control(ProfileControls.bio)
        ..value = ' ${'a' * UserProfileRemoteDataSource.maxBioLength}';

      expect(bio.hasError(ProfileErrors.tooLong), isTrue);
      form.dispose();
    });

    test('the player count is a whole number from 1 to 100, or blank', () {
      final form = profileFormGroup(() => _full);
      final count = form.control(ProfileControls.preferredPlayerCount);

      for (final valid in ['', '  ', '1', ' 7 ', '100']) {
        count.value = valid;
        expect(count.valid, isTrue, reason: '"$valid"');
      }
      for (final invalid in ['0', '101', '-1', '+3', '1.5', '0x5', 'two']) {
        count.value = invalid;
        expect(
          count.hasError(ProfileErrors.playerCount),
          isTrue,
          reason: '"$invalid"',
        );
      }
      form.dispose();
    });
  });
}
