import 'package:freezed_annotation/freezed_annotation.dart';

enum Visibility {
  @JsonValue('Friends')
  friends,
  @JsonValue('FriendsOfFriends')
  friendsOfFriends,
  @JsonValue('FriendsOfHouseholds')
  friendsOfHouseholds,
  @JsonValue('Household')
  household,
  @JsonValue('Private')
  private,
  @JsonValue('Public')
  public,
}
