import 'package:freezed_annotation/freezed_annotation.dart';
import 'friendship_status.dart';

part 'friendship.freezed.dart';
part 'friendship.g.dart';

@freezed
abstract class Friendship with _$Friendship {
  const factory Friendship({
    required String id,
    required String requestorId,
    required String recipientId,
    required FriendshipStatus status,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _Friendship;

  factory Friendship.fromJson(Map<String, dynamic> json) =>
      _$FriendshipFromJson(json);
}
