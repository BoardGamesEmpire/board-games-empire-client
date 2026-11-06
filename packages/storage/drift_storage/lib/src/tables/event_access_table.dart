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
/// - **`attending` rows come from the list, `read` rows from a detail read,
///   `household` rows from a household's list.**
///   The `GET /events` hydrate writes `attending` rows, and its purge removes
///   only the signed-in user's: their list speaks for their own attendance,
///   not anyone else's. A `GET /events/:id` the user made writes a `read` row,
///   which that purge leaves alone. A household's list writes `household`
///   rows (#503), which only its own purge removes.
/// - **An `attending` row keeps the list's answer (#667), and a `household`
///   row its list's (#503).** Each list carries the user's own attendance on
///   every row, and its pass writes it here, on the row it already writes for
///   them. The `GET /events` purge removes the `attending` row, and the
///   answer with it, and clears the answer on the `household` row. It isn't
///   put on the roster: one row on an event with no roster cached would read
///   as a roster of one.
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

  /// [eventAccessSourceAttending], [eventAccessSourceRead] or
  /// [eventAccessSourceHousehold].
  TextColumn get source => text()();

  /// The user's own answer as the `GET /events` row carried it (#667): their
  /// attendee id, `EventParticipationStatus` and `EventRole` by wire name,
  /// stored as `event_attendees` stores them, and when they last answered.
  ///
  /// Set only on `attending` and `household` rows, all four from one answer.
  /// Every write of an answer goes on both, where the rows exist, so they
  /// agree. Null on a row the list carried no answer for, or hasn't written
  /// since v15, and the list item then falls back to the user's own row on a
  /// cached roster. A detail read that carries an answer writes it here
  /// where the rows exist, and adds none.
  TextColumn get attendeeId => text().nullable()();
  TextColumn get attendanceStatus => text().nullable()();
  TextColumn get attendanceRole => text().nullable()();
  DateTimeColumn get rsvpDate => dateTime().nullable()();

  /// Whether this user's own detail read was shown the event's roster (#567):
  /// true when it carried at least one attendee, false when it carried none.
  ///
  /// Set only on `read` rows, by a write under the `read` source: a detail
  /// read, which is the one read that speaks for the roster, and the reconcile
  /// of a queued create, which writes the server's copy by a read's rules. A
  /// list row, which carries none, never touches it. A cached roster is served
  /// to a user it names and to one whose `read` row has this set, so it covers
  /// household members and staff without the client copying the server's role
  /// table. A row written before v17 holds false until the user's next detail
  /// read.
  ///
  /// The attendance purge also clears it, on the events it purges (#567): the
  /// flag can't tell whether the server showed the roster because the user
  /// attended, and the purge is the server saying they no longer do. A
  /// household's purge leaves it, as a household's list says nothing of the
  /// roster.
  BoolColumn get rosterShown => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {userId, eventId, source};

  @override
  String get tableName => 'event_access';
}

/// The source of an access row the `GET /events` hydrate wrote: an event the
/// user attends. It is the only source that hydrate's purge removes, and only
/// from the signed-in user's rows.
const String eventAccessSourceAttending = 'attending';

/// The source of an access row a `GET /events/:id` the user made wrote: an
/// event they read by id, whether or not they attend it.
const String eventAccessSourceRead = 'read';

/// The source of an access row a household's event list wrote (#503): an
/// event the household showed the user. Only that household's purge removes
/// it, and only from the signed-in user's rows.
const String eventAccessSourceHousehold = 'household';
