import 'package:drift/drift.dart';

import 'event_table.dart';

/// A cached copy of an event's policy, as `GET /events` and `GET /events/:id`
/// embed it (#496): who can be invited and join, and how the event's game
/// lineup is built.
///
/// Keyed by [eventId], because the server keeps at most one policy per event:
/// a write that carries one replaces the event's row, and the primary key is
/// the only index a lookup by event needs. [id] is the server's id for the
/// policy, kept as data.
///
/// The rest of the columns are `EventPolicy`'s fields, one each, and the model
/// says what each means. The five enum columns hold the backend's enum names
/// as text, with 'Unknown' for a name this client can't read, as
/// [EventsTable.type] does.
class EventPoliciesTable extends Table {
  TextColumn get id => text()();
  TextColumn get eventId => text().references(EventsTable, #id)();

  BoolColumn get allowMemberInvites => boolean()();
  BoolColumn get allowGuestInvites => boolean()();
  IntColumn get maxAttendees => integer().nullable()();
  BoolColumn get restrictToGameCategories => boolean()();
  BoolColumn get requireHostApprovalToJoin => boolean()();
  BoolColumn get allowSpectators => boolean()();
  IntColumn get maxTotalParticipants => integer().nullable()();
  BoolColumn get strictCapacity => boolean()();

  /// `GameAdditionMode`.
  TextColumn get gameAdditionMode => text()();
  BoolColumn get restrictToAttendeePool => boolean()();
  IntColumn get fillerMaxPlayTime => integer().nullable()();

  /// `VoteThresholdType`.
  TextColumn get voteThresholdType => text()();
  IntColumn get voteThresholdValue => integer().nullable()();

  /// `VoteQuorumType`.
  TextColumn get voteQuorumType => text()();
  IntColumn get voteQuorumValue => integer().nullable()();

  /// `VoteEligibility`.
  TextColumn get voteEligibility => text()();

  /// `InterestedWeight`.
  TextColumn get interestedWeight => text()();
  IntColumn get votingWindowHours => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {eventId};

  @override
  String get tableName => 'event_policies';
}
