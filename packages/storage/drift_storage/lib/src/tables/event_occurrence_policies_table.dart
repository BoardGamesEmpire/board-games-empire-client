import 'package:drift/drift.dart';

import 'package:drift_storage/src/tables/event_table.dart';

/// A cached copy of one date's own rules, laid over its event's policy, as
/// `GET /events/:id` serves them beside it (#1009).
///
/// Keyed by [occurrenceId], because the server keeps at most one per date. [id]
/// is the server's id for the rules, kept as data.
///
/// - **[eventId] references `events`.** A date's rules are read, replaced and
///   deleted by event, as its occurrence rows are.
/// - **[occurrenceId] references nothing.** Every read of an event deletes and
///   reinserts its `event_occurrences` rows, and with foreign keys enforced a
///   reference to them would refuse that delete.
/// - **Indexed on [eventId].** The primary key can't find an event's rows, and
///   SQLite looks up an `events` key's child rows on every change to that key.
///   Without the index, each lookup scans the whole table.
///
/// The columns are `EventOccurrencePolicy`'s fields, one each, and the model
/// says what each means. A nullable column is an override: null means the date
/// takes the event's value. The three list columns are JSON arrays of strings,
/// as `EventPoliciesTable`'s are, and `[]` means the event's list. The five
/// enum columns hold the backend's enum names as text, with 'Unknown' for a
/// name this client can't read, as [EventsTable.type] does.
@TableIndex(
  name: 'event_occurrence_policies_event_id_idx',
  columns: {#eventId},
)
class EventOccurrencePoliciesTable extends Table {
  TextColumn get id => text()();
  TextColumn get occurrenceId => text()();
  TextColumn get eventId => text().references(EventsTable, #id)();

  TextColumn get allowedCategoryIdsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get allowedPlatformIdsJson =>
      text().withDefault(const Constant('[]'))();

  /// `PlatformType` names, as `platform_games.platform_type` stores them.
  TextColumn get allowedPlatformTypesJson =>
      text().withDefault(const Constant('[]'))();

  BoolColumn get platformTypesUnrestricted => boolean()();
  BoolColumn get platformsUnrestricted => boolean()();
  BoolColumn get capacityUnrestricted => boolean()();

  BoolColumn get restrictToGameCategories => boolean().nullable()();
  BoolColumn get strictCapacity => boolean().nullable()();
  BoolColumn get requireHostApprovalToJoin => boolean().nullable()();
  BoolColumn get allowSpectators => boolean().nullable()();
  BoolColumn get restrictToAttendeePool => boolean().nullable()();
  IntColumn get maxAttendees => integer().nullable()();
  IntColumn get maxTotalParticipants => integer().nullable()();
  IntColumn get fillerMaxPlayTime => integer().nullable()();
  IntColumn get voteThresholdValue => integer().nullable()();
  IntColumn get voteQuorumValue => integer().nullable()();
  IntColumn get votingWindowHours => integer().nullable()();

  /// `GameAdditionMode`.
  TextColumn get gameAdditionMode => text().nullable()();

  /// `VoteThresholdType`.
  TextColumn get voteThresholdType => text().nullable()();

  /// `VoteQuorumType`.
  TextColumn get voteQuorumType => text().nullable()();

  /// `VoteEligibility`.
  TextColumn get voteEligibility => text().nullable()();

  /// `InterestedWeight`.
  TextColumn get interestedWeight => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {occurrenceId};

  @override
  String get tableName => 'event_occurrence_policies';
}
