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
  IntColumn get minPlayTime => integer().nullable()();
  TextColumn get minPlayTimeMeasure => text().nullable()();
  IntColumn get maxPlayTime => integer().nullable()();
  TextColumn get maxPlayTimeMeasure => text().nullable()();
  IntColumn get minAge => integer().nullable()();

  RealColumn get complexity => real().nullable()();
  TextColumn get contentType =>
      text().withDefault(const Constant('BaseGame'))();

  RealColumn get averageRating => real().nullable()();
  RealColumn get bayesRating => real().nullable()();
  IntColumn get ratingsCount => integer().nullable()();
  IntColumn get ownedByCount => integer().withDefault(const Constant(0))();

  // JSON arrays of names for categories, mechanics, designers, publishers
  TextColumn get categoriesJson => text().withDefault(const Constant('[]'))();
  TextColumn get mechanicsJson => text().withDefault(const Constant('[]'))();
  TextColumn get designersJson => text().withDefault(const Constant('[]'))();
  TextColumn get publishersJson => text().withDefault(const Constant('[]'))();

  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'games';
}
