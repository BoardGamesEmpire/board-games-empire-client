import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('Friendship', () {
    test('handles status transitions', () {
      final friendship = Friendship(
        id: 'f123',
        requestorId: 'user123',
        recipientId: 'user456',
        status: FriendshipStatus.pending,
      );

      final accepted = friendship.copyWith(status: FriendshipStatus.accepted);

      expect(accepted.status, FriendshipStatus.accepted);
    });

    test('serializes FriendshipStatus enum', () {
      final friendship = Friendship(
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
