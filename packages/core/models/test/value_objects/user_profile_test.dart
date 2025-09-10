import 'package:flutter_test/flutter_test.dart';
import 'package:models/value_objects.dart';
import 'package:models/domain.dart';

void main() {
  group('UserProfile Value Object', () {
    test('calculates display name correctly', () {
      final userWithFullName = User(
        id: 'user123',
        firstName: 'John',
        lastName: 'Doe',
        username: 'johndoe',
      );

      final profile = UserProfile(user: userWithFullName);
      expect(profile.displayName, 'John Doe');

      final userWithFirstOnly = User(
        id: 'user123',
        firstName: 'John',
        username: 'johndoe',
      );

      final profile2 = UserProfile(user: userWithFirstOnly);
      expect(profile2.displayName, 'John');

      final userWithUsernameOnly = User(id: 'user123', username: 'johndoe');

      final profile3 = UserProfile(user: userWithUsernameOnly);
      expect(profile3.displayName, 'johndoe');
    });

    test('generates initials correctly', () {
      final userWithFullName = User(
        id: 'user123',
        firstName: 'John',
        lastName: 'Doe',
        username: 'johndoe',
      );

      final profile = UserProfile(user: userWithFullName);
      expect(profile.initials, 'JD');

      final userWithFirstOnly = User(
        id: 'user123',
        firstName: 'John',
        username: 'johndoe',
      );

      final profile2 = UserProfile(user: userWithFirstOnly);
      expect(profile2.initials, 'JO');
    });

    test('detects avatar presence', () {
      final userWithProfileImage = User(
        id: 'user123',
        username: 'johndoe',
        avatar: 'avatar.jpg',
        profileImage: 'profile.jpg',
      );

      final profile = UserProfile(user: userWithProfileImage);
      expect(profile.hasAvatar, isTrue);
      expect(profile.avatarUrl, 'profile.jpg'); // Prefers profileImage

      final userWithoutAvatar = User(id: 'user456', username: 'janedoe');

      final profile2 = UserProfile(user: userWithoutAvatar);
      expect(profile2.hasAvatar, isFalse);
      expect(profile2.avatarUrl, isNull);
    });

    test('counts accepted friends', () {
      final user = User(id: 'user123', username: 'johndoe');
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
      final user = User(id: 'user123', username: 'johndoe');
      final preferences = UserPreferences(id: 'pref123', userId: 'user123');

      final profile1 = UserProfile(user: user, preferences: preferences);
      final profile2 = UserProfile(user: user, preferences: preferences);

      expect(profile1, equals(profile2));
    });
  });
}
