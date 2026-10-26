import 'package:drift/drift.dart';

/// A cached copy of an event, as `GET /events` and `GET /events/:id` return
/// it (#496).
///
/// One row per event per server, shared by every user signed in to it on this
/// device. Which users may read it is recorded in `event_access`
/// (`EventAccessTable`), and every event read goes through that table.
///
/// The event's occurrences, roster and policy are rows of their own, each
/// replaced by the reads that carry it: see `EventOccurrencesTable`,
/// `EventAttendeesTable` and `EventPoliciesTable`.
class EventsTable extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();

  /// The server's id for the account that created the event.
  TextColumn get createdById => text()();

  /// Null for an event outside any household.
  TextColumn get householdId => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get image => text().nullable()();

  /// The event-level place. An occurrence may override it with its own.
  TextColumn get location => text().nullable()();
  TextColumn get url => text().nullable()();

  /// `EventType`, as the backend's enum name. A name this client can't read
  /// is stored as 'Unknown', so a value a newer server adds can't fail the
  /// row.
  TextColumn get type => text()();

  /// `Reach`, stored as [type] is.
  TextColumn get reach => text()();

  /// `EventStatus`, stored as [type] is.
  TextColumn get status => text()();

  /// `EventSchedulingMode`, stored as [type] is.
  TextColumn get schedulingMode => text()();

  /// True when this row has local changes not yet synced to the server. Only
  /// `EventRepository.create` sets it yet, with [isLocalOnly], on the row it
  /// writes (#499). While either is set the row belongs to the sync queue,
  /// and no server read writes over it.
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();

  /// True when this row was created on this device and has not yet been
  /// confirmed by the server (#499). The reconcile deletes the row and writes
  /// the server's copy, which carries neither flag.
  BoolColumn get isLocalOnly => boolean().withDefault(const Constant(false))();

  /// Which write, by any user, last wrote this row: the `event_generation`
  /// counter's value when it did (`EventGenerationTable`). Not the server's:
  /// `updatedAt` is not bumped by attendee or vote writes, so it can't tell
  /// one read from the next.
  ///
  /// The hydrate's purge compares it with what it read before requesting
  /// page 1, and leaves an event that has been written since. That write,
  /// another tab's pass or a detail read, may come from a newer read than
  /// the page the purge judges, so it can't stand as proof the event left
  /// the user's list. The counter never repeats a value, so neither does an
  /// event deleted and cached again.
  IntColumn get generation => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'events';
}
