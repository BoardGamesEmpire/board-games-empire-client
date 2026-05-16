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
  public;

  /// Wire-format string used both by the server JSON contract (via the
  /// [JsonValue] annotation on each case above) and by the Drift
  /// storage layer.
  ///
  /// The two coexist because Drift mappers read raw columns and don't
  /// run json_serializable, so they need an explicit way to convert
  /// the enum to its wire string. Keep this switch in sync with the
  /// [JsonValue] annotations.
  String toWire() => switch (this) {
    Visibility.friends => 'Friends',
    Visibility.friendsOfFriends => 'FriendsOfFriends',
    Visibility.friendsOfHouseholds => 'FriendsOfHouseholds',
    Visibility.household => 'Household',
    Visibility.private => 'Private',
    Visibility.public => 'Public',
  };

  /// Inverse of [toWire]. Throws [StateError] for unrecognised values
  /// rather than coercing to a default — a storage row or wire payload
  /// with an unknown visibility represents either DB corruption or a
  /// server-side enum extension the client hasn't been updated for,
  /// and both must surface rather than be silently coerced.
  static Visibility fromWire(String value) => switch (value) {
    'Friends' => Visibility.friends,
    'FriendsOfFriends' => Visibility.friendsOfFriends,
    'FriendsOfHouseholds' => Visibility.friendsOfHouseholds,
    'Household' => Visibility.household,
    'Private' => Visibility.private,
    'Public' => Visibility.public,
    _ => throw StateError('Unknown Visibility wire value: "$value"'),
  };
}
