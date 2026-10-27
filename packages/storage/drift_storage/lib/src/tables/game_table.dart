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

  /// Play time, in minutes. One playing time is a range whose two ends are
  /// equal (backend#869).
  IntColumn get minPlayTime => integer().nullable()();
  IntColumn get maxPlayTime => integer().nullable()();
  IntColumn get minAge => integer().nullable()();

  RealColumn get complexity => real().nullable()();
  TextColumn get contentType =>
      text().withDefault(const Constant('BaseGame'))();

  /// Aggregate play count across all users (server-provided).
  IntColumn get totalPlayCount => integer().withDefault(const Constant(0))();

  RealColumn get averageRating => real().nullable()();
  RealColumn get bayesRating => real().nullable()();
  IntColumn get ratingsCount => integer().nullable()();
  IntColumn get ownedByCount => integer().withDefault(const Constant(0))();

  // JSON arrays of names for the denormalised relation lists.
  TextColumn get categoriesJson => text().withDefault(const Constant('[]'))();
  TextColumn get mechanicsJson => text().withDefault(const Constant('[]'))();
  TextColumn get designersJson => text().withDefault(const Constant('[]'))();
  TextColumn get publishersJson => text().withDefault(const Constant('[]'))();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();

  /// `Reach`, as the backend's enum name; a name this client can't read is
  /// stored as 'Unknown'. A row cached before v11 keeps the visibility name it
  /// had, so an old 'Household' reads as unknown too. Default 'Public', the
  /// server's default (#602).
  TextColumn get reach => text().withDefault(const Constant('Public'))();

  /// Server user id of the row's creator. Nullable for legacy/imported
  /// games whose creator is unknown.
  TextColumn get createdById => text().nullable()();

  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// When this device last cached the game's full record, by the local
  /// clock (#406).
  ///
  /// Null on a row only a collection summary has written, whose other
  /// columns are defaults, not the server's values. The repository's reads
  /// skip such a row, and a summary write never sets or clears this.
  DateTimeColumn get fullRecordCachedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'games';
}
