import 'package:drift/drift.dart';

import 'event_table.dart';

/// Which users each cached event was sent to (#496): one row per user, event
/// and [source], shaped like `GameAccessTable` (#434).
///
/// `events` holds each event once per server, shared by every user signed in
/// to it on this device. Every event read returns only events the reading user
/// has a row here for, so one user can't list or look up an event the server
/// sent only to another.
///
/// - **[source] is part of the key.** An event a user both attends and has
///   read keeps both reasons, so removing one can't take away the other.
/// - **`attending` rows come from the list, `read` rows from a detail read.**
///   The `GET /events` hydrate writes `attending` rows, and they are the only
///   rows its purge removes. A `GET /events/:id` the user made writes a `read`
///   row, which that purge leaves alone.
/// - **An event goes with its last row.** Once no row is left for an event, it
///   is deleted, with its occurrences, roster and policy.
/// - **Indexed on [eventId].** The primary key leads with [userId], so it
///   can't find an event's rows. Two lookups need them: the check for a last
///   row, and SQLite's foreign key check on every change to an `events` key.
///   Without the index, each scans the whole table.
@TableIndex(name: 'event_access_event_id_idx', columns: {#eventId})
class EventAccessTable extends Table {
  TextColumn get userId => text()();
  TextColumn get eventId => text().references(EventsTable, #id)();

  /// [eventAccessSourceAttending] or [eventAccessSourceRead].
  TextColumn get source => text()();

  @override
  Set<Column> get primaryKey => {userId, eventId, source};

  @override
  String get tableName => 'event_access';
}

/// The source of an access row the `GET /events` hydrate wrote: an event the
/// user attends. It is the only source that hydrate's purge removes.
const String eventAccessSourceAttending = 'attending';

/// The source of an access row a `GET /events/:id` the user made wrote: an
/// event they read by id, whether or not they attend it.
const String eventAccessSourceRead = 'read';
