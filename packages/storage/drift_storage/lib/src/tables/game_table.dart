import 'package:drift/drift.dart';

class GamesTable extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get subtitle => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get image => text().nullable()();
  TextColumn get thumbnail => text().nullable()();
  IntColumn get publishYear => integer().nullable()();

  IntColumn get minPlayers => integer().nullable()();
  IntColumn get maxPlayers => integer().nullable()();

  /// Aggregate playing time in minutes (server `Game.playingTime`).
  /// Distinct from [minPlayTime] / [maxPlayTime] which carry per-end
  /// values with their own unit measure columns.
  IntColumn get playingTime => integer().nullable()();

  IntColumn get minPlayTime => integer().nullable()();
  TextColumn get minPlayTimeMeasure => text().nullable()();
  IntColumn get maxPlayTime => integer().nullable()();
  TextColumn get maxPlayTimeMeasure => text().nullable()();
  IntColumn get minAge => integer().nullable()();

  RealColumn get complexity => real().nullable()();
  TextColumn get contentType =>
      text().withDefault(const Constant('BaseGame'))();

  /// Aggregate play count across all users (server-provided).
  IntColumn get totalPlayCount =>
      integer().withDefault(const Constant(0))();

  RealColumn get averageRating => real().nullable()();
  RealColumn get bayesRating => real().nullable()();
  IntColumn get ratingsCount => integer().nullable()();
  IntColumn get ownedByCount =>
      integer().withDefault(const Constant(0))();

  // JSON arrays of names for the denormalised relation lists.
  TextColumn get categoriesJson => text().withDefault(const Constant('[]'))();
  TextColumn get mechanicsJson => text().withDefault(const Constant('[]'))();
  TextColumn get designersJson => text().withDefault(const Constant('[]'))();
  TextColumn get publishersJson => text().withDefault(const Constant('[]'))();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();

  /// Visibility wire format (PascalCase: 'Public', 'Private', 'Household',
  /// 'Friends', 'FriendsOfFriends', 'FriendsOfHouseholds'). Matches the
  /// [JsonValue] annotations on the [Visibility] enum. Default 'Public'
  /// mirrors the model's default.
  TextColumn get visibility =>
      text().withDefault(const Constant('Public'))();

  /// Server user id of the row's creator. Nullable for legacy/imported
  /// games whose creator is unknown.
  TextColumn get createdById => text().nullable()();

  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'games';
}
