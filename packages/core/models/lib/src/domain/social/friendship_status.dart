import 'package:freezed_annotation/freezed_annotation.dart';

enum FriendshipStatus {
  @JsonValue('Accepted')
  accepted,
  @JsonValue('Blocked')
  blocked,
  @JsonValue('Declined')
  declined,
  @JsonValue('Pending')
  pending,
  @JsonValue('Unfriended')
  unfriended,
}
