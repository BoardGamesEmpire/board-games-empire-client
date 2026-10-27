import 'package:freezed_annotation/freezed_annotation.dart';

/// How far past its owner something reaches: only them, their friends, friends
/// of friends, or everyone signed in to the server.
///
/// Mirrors the backend's `Reach` enum (`prisma/models/enums/reach.prisma` in
/// `board-games-empire-backend`). The backend shares it across resources rather
/// than tying it to events, so it lives beside `Visibility` and not with the
/// event types (#496).
///
/// The values follow the backend's alphabetical order, not the order of the
/// ladder, so their `index` says nothing about how far one reaches.
///
/// The `@JsonValue` names are the backend's, so a model's JSON keeps them, as
/// `ContentType`'s does. [fromWire] / [toWire] must agree with them, apart
/// from [unknown], which has a JSON name but no wire name.
enum Reach {
  @JsonValue('Friends')
  friends,
  @JsonValue('FriendsOfFriends')
  friendsOfFriends,
  @JsonValue('Private')
  private,
  @JsonValue('Public')
  public,

  /// A name this client does not know. Never sent.
  @JsonValue('Unknown')
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static Reach fromWire(String name) => switch (name) {
    'Friends' => Reach.friends,
    'FriendsOfFriends' => Reach.friendsOfFriends,
    'Private' => Reach.private,
    'Public' => Reach.public,
    _ => Reach.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    Reach.friends => 'Friends',
    Reach.friendsOfFriends => 'FriendsOfFriends',
    Reach.private => 'Private',
    Reach.public => 'Public',
    Reach.unknown => throw StateError('Reach.unknown has no wire name'),
  };
}
