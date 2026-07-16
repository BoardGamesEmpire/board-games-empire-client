import 'package:flutter_test/flutter_test.dart';
import 'package:models/value_objects.dart';
import 'package:models/domain.dart';

/// Builds a [User] with the now-required identity fields filled in, so each
/// test only specifies the fields it actually exercises.
User buildUser({
  String id = 'user123',
  String username = 'johndoe',
  String? firstName,
  String? lastName,
  String? image,
}) => User(
  id: id,
  username: username,
  firstName: firstName,
  lastName: lastName,
  image: image,
  email: 'test@example.com',
  emailVerified: true,
  createdAt: DateTime.utc(2024, 1, 1),
  updatedAt: DateTime.utc(2024, 1, 2),
);

void main() {
  group('UserProfile Value Object', () {
    test('calculates display name correctly', () {
      final userWithFullName = buildUser(firstName: 'John', lastName: 'Doe');

      final profile = UserProfile(user: userWithFullName);
      expect(profile.displayName, 'John Doe');

      final userWithFirstOnly = buildUser(firstName: 'John');

      final profile2 = UserProfile(user: userWithFirstOnly);
      expect(profile2.displayName, 'John');

      final userWithUsernameOnly = buildUser();

      final profile3 = UserProfile(user: userWithUsernameOnly);
      expect(profile3.displayName, 'johndoe');
    });

    test('generates initials correctly', () {
      final userWithFullName = buildUser(firstName: 'John', lastName: 'Doe');

      final profile = UserProfile(user: userWithFullName);
      expect(profile.initials, 'JD');

      final userWithFirstOnly = buildUser(firstName: 'John');

      final profile2 = UserProfile(user: userWithFirstOnly);
      expect(profile2.initials, 'JO');
    });

    test('detects avatar presence', () {
      final userWithImage = buildUser(image: 'profile.jpg');

      final profile = UserProfile(user: userWithImage);
      expect(profile.hasAvatar, isTrue);
      expect(profile.avatarUrl, 'profile.jpg');

      final userWithoutAvatar = buildUser(id: 'user456', username: 'janedoe');

      final profile2 = UserProfile(user: userWithoutAvatar);
      expect(profile2.hasAvatar, isFalse);
      expect(profile2.avatarUrl, isNull);
    });

    test('counts accepted friends', () {
      final user = buildUser();
      final friendships = [
        Friendship(
          id: 'f1',
          requestorId: 'user123',
          recipientId: 'user456',
          status: FriendshipStatus.accepted,
        ),
        Friendship(
          id: 'f2',
          requestorId: 'user789',
          recipientId: 'user123',
          status: FriendshipStatus.accepted,
        ),
        Friendship(
          id: 'f3',
          requestorId: 'user123',
          recipientId: 'user999',
          status: FriendshipStatus.pending,
        ),
      ];

      final profile = UserProfile(user: user, friendships: friendships);
      expect(profile.friendCount, 2);
    });

    test('maintains equality', () {
      final user = buildUser();
      final preferences = UserPreferences(id: 'pref123', userId: 'user123');

      final profile1 = UserProfile(user: user, preferences: preferences);
      final profile2 = UserProfile(user: user, preferences: preferences);

      expect(profile1, equals(profile2));
    });
  });
}
