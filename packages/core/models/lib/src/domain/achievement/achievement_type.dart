import 'package:freezed_annotation/freezed_annotation.dart';

enum AchievementType {
  @JsonValue('Collector')
  collector,
  @JsonValue('Completionist')
  completionist,
  @JsonValue('EventsAttended')
  eventsAttended,
  @JsonValue('EventsHosted')
  eventsHosted,
  @JsonValue('FriendsAdded')
  friendsAdded,
  @JsonValue('GameMaster')
  gameMaster,
  @JsonValue('GameMastery')
  gameMastery,
  @JsonValue('GamesOwned')
  gamesOwned,
  @JsonValue('GamesPlayed')
  gamesPlayed,
  @JsonValue('GamesRated')
  gamesRated,
  @JsonValue('PlayStreak')
  playStreak,
  @JsonValue('Socialite')
  socialite,
  @JsonValue('WinStreak')
  winStreak,
}
