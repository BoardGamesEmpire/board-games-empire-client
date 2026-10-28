import 'package:drift/drift.dart';

import 'event_table.dart';

/// A cached copy of one of an event's occurrences, as `GET /events` and
/// `GET /events/:id` embed them (#496): when it happens, and where if that
/// differs from the event's own place.
///
/// Both reads serve all of an event's occurrences, so every write of the event
/// replaces its rows here wholesale, and one the server no longer returns
/// doesn't linger.
///
/// Indexed on [eventId], because an event's occurrences are read and replaced
/// by event, and SQLite looks up an `events` key's child rows on every change
/// to that key. Without the index, each lookup scans the whole table.
@TableIndex(name: 'event_occurrences_event_id_idx', columns: {#eventId})
class EventOccurrencesTable extends Table {
  TextColumn get id => text()();
  TextColumn get eventId => text().references(EventsTable, #id)();

  /// A name for this occurrence, such as "Day 1".
  TextColumn get label => text().nullable()();

  /// Null means the date is still to be set.
  DateTimeColumn get startDate => dateTime().nullable()();
  DateTimeColumn get endDate => dateTime().nullable()();

  /// Overrides the event's place for this occurrence alone.
  TextColumn get location => text().nullable()();

  /// `OccurrenceStatus`, as the backend's enum name. A name this client can't
  /// read is stored as 'Unknown', so a value a newer server adds can't fail
  /// the row.
  TextColumn get status => text()();

  /// Where this occurrence falls among the event's, lowest first. Occurrences
  /// that share a value are ordered by id.
  IntColumn get sortOrder => integer()();

  DateTimeColumn get confirmedAt => dateTime().nullable()();
  DateTimeColumn get declinedAt => dateTime().nullable()();
  DateTimeColumn get cancelledAt => dateTime().nullable()();

  /// Why the host cancelled it, when they said (#506).
  TextColumn get cancelReason => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'event_occurrences';
}
