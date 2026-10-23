import 'package:drift/drift.dart';

/// The last `generation` an event write took on this server (#496): one row,
/// [id] 0, never deleted.
///
/// Every write of a page or a detail read counts it up by one and stamps the
/// events it wrote with the new value, so an event's `generation` never
/// repeats, even for an event deleted and later cached again. Counted on the
/// event's own row instead, it would start over with the new row, at the
/// value a purge may still hold for the deleted one, and that purge would
/// take the new row for the one it read.
///
/// A counter rather than a time, so a device clock that moves backwards
/// can't repeat it either. Created empty: the first write inserts the row.
class EventGenerationTable extends Table {
  /// Always 0. A key only, so a write can count up the one row in place.
  IntColumn get id => integer()();

  IntColumn get lastGeneration => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'event_generation';
}
