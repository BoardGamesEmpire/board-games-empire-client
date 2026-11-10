import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('Friendship', () {
    test('handles status transitions', () {
      const friendship = Friendship(
        id: 'f123',
        requestorId: 'user123',
        recipientId: 'user456',
        status: FriendshipStatus.pending,
      );

      final accepted = friendship.copyWith(status: FriendshipStatus.accepted);

      expect(accepted.status, FriendshipStatus.accepted);
    });

    test('serializes FriendshipStatus enum', () {
      const friendship = Friendship(
        id: 'f123',
        requestorId: 'user123',
        recipientId: 'user456',
        status: FriendshipStatus.blocked,
      );

      final json = friendship.toJson();

      expect(json['status'], 'Blocked');
    });
  });
}
