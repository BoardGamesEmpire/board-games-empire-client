import 'package:drift/drift.dart';
import 'dart:convert';

@DataClassName('ServerConfigData')
class ServerConfigs extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text().named('display_name')();
  TextColumn get serverUrl => text().named('server_url')();
  TextColumn get connectionState => text().named('connection_state')();
  DateTimeColumn get lastActiveAt =>
      dateTime().named('last_active_at').nullable()();
  TextColumn get metadata =>
      text().map(const JsonMapConverter()).withDefault(const Constant('{}'))();
  DateTimeColumn get createdAt =>
      dateTime().named('created_at').withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt =>
      dateTime().named('updated_at').withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {serverUrl},
  ];
}

class JsonMapConverter extends TypeConverter<Map<String, dynamic>, String> {
  const JsonMapConverter();

  @override
  Map<String, dynamic> fromSql(String fromDb) {
    return json.decode(fromDb) as Map<String, dynamic>;
  }

  @override
  String toSql(Map<String, dynamic> value) {
    return json.encode(value);
  }
}
