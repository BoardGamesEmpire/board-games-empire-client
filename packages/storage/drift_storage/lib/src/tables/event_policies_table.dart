import 'package:drift/drift.dart';

import 'package:drift_storage/src/tables/event_table.dart';

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
/// says what each means. The six enum columns hold the backend's enum names
/// as text, with 'Unknown' for a name this client can't read, as
/// [EventsTable.type] does.
///
/// A date's own rules, laid over this policy, are in
/// `EventOccurrencePoliciesTable` (#1009).
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

  /// `OccurrenceOverrideScope` (#1009). Defaults to 'Any', the server's
  /// default, which a policy cached before v19 holds until a read writes the
  /// event's own.
  TextColumn get occurrenceOverrideScope =>
      text().withDefault(const Constant('Any'))();

  /// The lists a restriction allows, each a JSON array of strings (#1009):
  /// `PlatformType` names as `platform_games.platform_type` stores them,
  /// platform ids and category ids. Null means no read has carried the list,
  /// as the model's null does. It never means no restriction, and `[]` is a
  /// list a read carried.
  TextColumn get allowedPlatformTypesJson => text().nullable()();
  TextColumn get allowedPlatformIdsJson => text().nullable()();
  TextColumn get allowedCategoryIdsJson => text().nullable()();

  /// Whether a read has carried the event's dates' own rules (#1009), so the
  /// rows `EventOccurrencePoliciesTable` holds for the event are all it has,
  /// none included. Only a detail read carries them, and it sets this as it
  /// replaces them. The lists above can't say it: a create's answer and a
  /// policy edit's carry the lists without the dates' rules. A policy written
  /// any other way, or cached before v19, holds false, read as the dates'
  /// rules not known, until a detail read.
  BoolColumn get occurrencePoliciesRead =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {eventId};

  @override
  String get tableName => 'event_policies';
}
