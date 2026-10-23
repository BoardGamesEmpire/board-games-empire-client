import 'package:drift/drift.dart';

import 'event_table.dart';

/// A cached copy of one person on an event's roster, as `GET /events/:id`
/// embeds it (#496): an account holder, or a guest who has none.
///
/// Only a detail read carries a roster, and only one that returned at least
/// one attendee replaces the rows here. The list carries none, and an empty
/// roster from a detail read can mean the caller may not read it rather than
/// that nobody is on it, so neither is evidence the cached roster is stale.
///
/// The rows hold other people's names, guests' names and their notes, and
/// like `events` they are shared by every user signed in to this server on
/// this device. The server shows a roster only to the event's attendees and
/// its household's members (backend#560), so `EventRepositoryImpl` serves the
/// rows only to a user with a row of their own on the same roster.
///
/// - **Indexed on [eventId].** A roster is read and replaced by event, and
///   SQLite looks up an `events` key's child rows on every change to that
///   key. Without the index, each lookup scans the whole table.
/// - **Indexed on [userId].** It finds the rows that name one user, such as
///   their own place on a roster.
@TableIndex(name: 'event_attendees_event_id_idx', columns: {#eventId})
@TableIndex(name: 'event_attendees_user_id_idx', columns: {#userId})
class EventAttendeesTable extends Table {
  TextColumn get id => text()();
  TextColumn get eventId => text().references(EventsTable, #id)();

  /// The attendee's account. Null for a guest, who has none.
  TextColumn get userId => text().nullable()();

  /// A guest's name, as it was given when they were added.
  TextColumn get guestName => text().nullable()();

  /// The account's name, display name and avatar, as the roster embeds them.
  /// All three are null for a guest, and the last two are also null for an
  /// account that has not set them.
  TextColumn get username => text().nullable()();
  TextColumn get displayName => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get notes => text().nullable()();

  /// `EventParticipationStatus`, as the backend's enum name. A name this
  /// client can't read is stored as 'Unknown', so a value a newer server adds
  /// can't fail the row.
  TextColumn get status => text()();

  /// `EventRole`, as the name of the role the server binds to the attendee
  /// (`EventHost`, `EventParticipant`, and so on). Null when the server
  /// returns no role binding. A name this client can't read, such as a role a
  /// deployment defines, is stored as 'Unknown'.
  TextColumn get roleName => text().nullable()();

  /// When the attendee last answered yes or no. Null until they have.
  DateTimeColumn get rsvpDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'event_attendees';
}
