import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';
import '../tables/event_access_table.dart';
import 'watch_disposal.dart';

/// [EventRepository] over the per-server [ServerDatabase], for one user
/// (#496).
///
/// ## One copy of each event, read per user
///
/// `events` and the four tables beside it hold each row once per server,
/// whichever users it was cached for. Every write also records the event for
/// this repository's user in `event_access`, under the source of the read
/// that brought it, and every read returns only events recorded for that
/// user. So a user signed in to the same server on this device after another
/// can't list or look up what the server sent only to the other. The roster
/// is narrower still: [getEvent] serves it only to a user it names.
///
/// The user is fixed at construction, as `GameRepositoryImpl`'s is. A page
/// the hydrate writes after its session has ended, before the scope finishes
/// popping, still records its events for the user they came from. No method
/// takes a user id.
///
/// ## Disposal
///
/// Registered in the user-session scope, which pops on sign-out, a server
/// switch, suspend and context dispose. Its Drift stream is tied to the
/// per-server database, which outlives that scope, so it takes the shared
/// [WatchDisposal] contract (#138): after `onDispose()` the `Future` methods
/// throw [StateError], and [watchAttendingEvents] and [watchEvent] close.
class EventRepositoryImpl with WatchDisposal implements EventRepository {
  EventRepositoryImpl(this._db, {required this._userId});

  final ServerDatabase _db;
  final String _userId;

  /// What an enum column holds for a value this client could not read. No
  /// enum has it as a wire name, so each one's `fromWire` reads it back as
  /// `unknown`, as it does any other name it doesn't know.
  static const String _unknownName = 'Unknown';

  @override
  String get disposedRepositoryName => 'EventRepository';

  // ── Writes ─────────────────────────────────────────────────────────────

  @override
  Future<void> cacheEvent(
    EventSnapshot snapshot, {
    required EventAccessSource source,
  }) async {
    checkNotDisposed();
    await _writeSnapshots([snapshot], source);
  }

  @override
  Future<void> cacheEvents(
    List<EventSnapshot> snapshots, {
    required EventAccessSource source,
  }) async {
    checkNotDisposed();
    await _writeSnapshots(snapshots, source);
  }

  /// Writes [snapshots] for this user under [source]: the steps
  /// [EventRepository.cacheEvent] lists, for every snapshot at once.
  ///
  /// One batch, which is one transaction, so Drift tells a live query about
  /// the page once, and one round trip, which on web is one message to the
  /// database worker rather than several per event.
  Future<void> _writeSnapshots(
    List<EventSnapshot> snapshots,
    EventAccessSource source,
  ) async {
    // An event named twice is written from its later snapshot alone, so its
    // occurrences and roster aren't inserted twice.
    final byId = {for (final s in snapshots) s.event.id: s};
    if (byId.isEmpty) return;
    final written = byId.values;

    // The list carries no roster, and an empty one is a roster the caller
    // may not read, so only a roster with someone on it replaces the cached
    // one.
    final rosters = {
      for (final s in written)
        if (s.attendees case final attendees? when attendees.isNotEmpty)
          s.event.id: attendees,
    };
    // But an empty one does say the caller isn't on it, since an attendee
    // always sees themselves. Kept, their own row would go on passing the
    // roster rule, and showing them everyone else on it.
    final refused = {
      for (final s in written)
        if (s.attendees case final attendees? when attendees.isEmpty)
          s.event.id,
    };

    await _db.batch((b) {
      // The events first, since the other four tables reference them and
      // foreign keys are enforced. An upsert, not a REPLACE, which would
      // delete the rows their keys name before writing them again.
      b.insertAllOnConflictUpdate(_db.eventsTable, [
        for (final s in written) _eventToCompanion(s.event),
      ]);
      // Every write takes the next generation, so a purge that read the
      // events before this one can tell it happened. From the shared
      // counter, not the event's own row, which a purge may have deleted
      // since: a row counted afresh would repeat the deleted one's.
      final counter = _db.eventGenerationTable;
      b.insert(
        counter,
        const EventGenerationTableCompanion(
          id: Value(0),
          lastGeneration: Value(1),
        ),
        onConflict: DoUpdate(
          ($EventGenerationTableTable old) =>
              EventGenerationTableCompanion.custom(
                lastGeneration: old.lastGeneration + const Constant(1),
              ),
        ),
      );
      b.update(
        _db.eventsTable,
        EventsTableCompanion.custom(
          generation: subqueryExpression<int>(
            _db.selectOnly(counter)..addColumns([counter.lastGeneration]),
          ),
        ),
        where: (t) => t.id.isIn(byId.keys),
      );

      // A snapshot without a policy says nothing about the cached one: a
      // read serves none to a caller its own check refuses, and the server
      // has no policy delete.
      b.insertAllOnConflictUpdate(_db.eventPoliciesTable, [
        for (final s in written)
          if (s.policy case final policy?) _policyToCompanion(policy),
      ]);

      // Both reads carry every occurrence, and the server hard-deletes one,
      // so an empty list clears them.
      b.deleteWhere(
        _db.eventOccurrencesTable,
        (t) => t.eventId.isIn(byId.keys),
      );
      b.insertAll(_db.eventOccurrencesTable, [
        for (final s in written) ...s.occurrences.map(_occurrenceToCompanion),
      ]);

      if (rosters.isNotEmpty) {
        b.deleteWhere(
          _db.eventAttendeesTable,
          (t) => t.eventId.isIn(rosters.keys),
        );
        b.insertAll(_db.eventAttendeesTable, [
          for (final roster in rosters.values)
            ...roster.map(_attendeeToCompanion),
        ]);
      }
      if (refused.isNotEmpty) {
        b.deleteWhere(
          _db.eventAttendeesTable,
          (t) => t.eventId.isIn(refused) & t.userId.equals(_userId),
        );
      }

      b.insertAll(_db.eventAccessTable, [
        for (final eventId in byId.keys)
          EventAccessTableCompanion.insert(
            userId: _userId,
            eventId: eventId,
            source: _encodeSource(source),
          ),
      ], mode: InsertMode.insertOrIgnore);
    });
  }

  // ── Purge ──────────────────────────────────────────────────────────────

  @override
  Future<Map<String, int>> purgeableAttendance() async {
    checkNotDisposed();
    return _purgeableAttendance();
  }

  @override
  Future<Set<String>> purgeAttendanceAbsentFrom(
    Set<String> snapshotIds, {
    required Map<String, int> purgeable,
    DateTime? newerThan,
  }) async {
    checkNotDisposed();
    return _db.transaction(() async {
      // Read again here: [purgeable] predates the snapshot, and an event in
      // it may have been edited since, which hands it to the queue, or
      // written again from a newer read than the snapshot.
      final current = await _purgeableAttendance(newerThan: newerThan);
      final purged = {
        for (final MapEntry(key: id, value: generation) in current.entries)
          if (purgeable[id] == generation && !snapshotIds.contains(id)) id,
      };
      if (purged.isEmpty) return const <String>{};

      // This user's attendance only. The list speaks for nobody else's, nor
      // for what this user may read by id.
      await (_db.delete(_db.eventAccessTable)..where(
            (t) =>
                t.userId.equals(_userId) &
                t.source.equals(eventAccessSourceAttending) &
                t.eventId.isIn(purged),
          ))
          .go();

      // And their own place on those rosters. The list holds every event
      // they have an attendee row in that no host has removed, so one it
      // leaves out is one they no longer attend. Kept, where a `read` row
      // still lets them read the event, their old row would answer with
      // their role and RSVP, and pass the roster rule. Everyone else's rows
      // stay.
      await (_db.delete(
        _db.eventAttendeesTable,
      )..where((t) => t.userId.equals(_userId) & t.eventId.isIn(purged))).go();

      await _deleteUnreachable(purged);
      return purged;
    });
  }

  @override
  Future<int?> lastWrite(String id) async {
    checkNotDisposed();
    final t = _db.eventsTable;
    final query = _db.selectOnly(t)
      ..addColumns([t.generation])
      ..where(t.id.equals(id) & _readableEvent(t));
    return (await query.getSingleOrNull())?.read(t.generation);
  }

  @override
  Future<bool> forgetEvent(String id, {required int lastWrite}) async {
    checkNotDisposed();
    return _db.transaction(() async {
      // Only an event this user can read, and not one the sync queue owns.
      // A local-only event is one the server has never heard of, so a 404
      // for its id says nothing about it, and a dirty one carries an edit
      // the queue has yet to send (#298's rule for households).
      final event = await (_db.select(
        _db.eventsTable,
      )..where((t) => t.id.equals(id) & _readableEvent(t))).getSingleOrNull();
      if (event == null || event.isDirty || event.isLocalOnly) return false;
      // Nor one written since the read was sent, which may be newer news
      // than its 404, as the purge leaves one alone.
      if (event.generation != lastWrite) return false;

      // Both sources, where the purge removes `attending` alone. The list
      // speaks for a user's attendance and nothing else, but an event the
      // server refuses this user by id is closed to them by either route.
      // Theirs only: another user's access stays, and the event with it.
      await (_db.delete(
        _db.eventAccessTable,
      )..where((t) => t.userId.equals(_userId) & t.eventId.equals(id))).go();

      // And their own place on the roster, for the reason the purge gives:
      // kept, it would still answer with their old role and RSVP and pass
      // the roster rule for whoever reads the event next. Everyone else's
      // rows stay.
      await (_db.delete(
        _db.eventAttendeesTable,
      )..where((t) => t.userId.equals(_userId) & t.eventId.equals(id))).go();

      await _deleteUnreachable({id});
      return true;
    });
  }

  /// Deletes each of [eventIds] that no user, by any source, has an access
  /// row for any longer, with its occurrences, roster and policy: an event
  /// no read can reach.
  ///
  /// The children go first, for their foreign keys. Run inside the
  /// transaction that removed the access.
  Future<void> _deleteUnreachable(Set<String> eventIds) async {
    await (_db.delete(
      _db.eventOccurrencesTable,
    )..where((t) => _unreachable(t.eventId, eventIds))).go();
    await (_db.delete(
      _db.eventAttendeesTable,
    )..where((t) => _unreachable(t.eventId, eventIds))).go();
    await (_db.delete(
      _db.eventPoliciesTable,
    )..where((t) => _unreachable(t.eventId, eventIds))).go();
    await (_db.delete(
      _db.eventsTable,
    )..where((t) => _unreachable(t.id, eventIds))).go();
  }

  /// The events this user has `attending` access to, less any carrying local
  /// changes, and only those created strictly after [newerThan] when it is
  /// given, each with its `generation`.
  ///
  /// An event that is `isDirty` or `isLocalOnly` belongs to the sync queue
  /// until the server acknowledges it, so no purge takes it, as #298 has it
  /// for households.
  ///
  /// [newerThan] is compared as an instant, through `JULIANDAY`, since as
  /// ISO-8601 text `…00.345Z` sorts after `…00.345001Z` (#441). An event at
  /// the same millisecond is left out on purpose: the server breaks that tie
  /// by id, in a collation SQLite's text order doesn't match, so this device
  /// can't tell which side of a page boundary it fell on.
  Future<Map<String, int>> _purgeableAttendance({DateTime? newerThan}) async {
    final t = _db.eventsTable;
    var purgeable =
        t.id.isInQuery(_accessedEventIds(eventAccessSourceAttending)) &
        t.isDirty.equals(false) &
        t.isLocalOnly.equals(false);
    if (newerThan != null) {
      purgeable =
          purgeable &
          t.createdAt.julianday.isBiggerThan(
            Variable<DateTime>(newerThan).julianday,
          );
    }
    final query = _db.selectOnly(t)
      ..addColumns([t.id, t.generation])
      ..where(purgeable);
    return {
      for (final row in await query.get())
        row.read(t.id)!: row.read(t.generation)!,
    };
  }

  /// Whether [eventId] is one of [eventIds] that no user, by any source, has
  /// an access row for any longer.
  Expression<bool> _unreachable(
    Expression<String> eventId,
    Set<String> eventIds,
  ) {
    final access = _db.eventAccessTable;
    return eventId.isIn(eventIds) &
        eventId.isNotInQuery(
          _db.selectOnly(access)
            ..addColumns([access.eventId])
            ..where(access.eventId.isIn(eventIds)),
        );
  }

  // ── Reads ──────────────────────────────────────────────────────────────

  /// The ids of the events this user has an access row for, from [source]
  /// alone when one is given.
  JoinedSelectStatement<$EventAccessTableTable, EventAccessTableData>
  _accessedEventIds([String? source]) {
    final access = _db.eventAccessTable;
    var mine = access.userId.equals(_userId);
    if (source != null) mine = mine & access.source.equals(source);
    return _db.selectOnly(access)
      ..addColumns([access.eventId])
      ..where(mine);
  }

  /// Whether every event read may return the `events` row [t]: one the
  /// server sent this user, through either read. Rows cached only for other
  /// users are hidden, because the server never sent them to this one.
  Expression<bool> _readableEvent($EventsTableTable t) =>
      t.id.isInQuery(_accessedEventIds());

  /// Whether a roster read may return the `event_attendees` row [t]: one on
  /// a roster that names this user.
  ///
  /// The rows are shared by every user signed in to this server on this
  /// device, and they hold other people's names and notes. The server shows
  /// a roster to the event's attendees and to its household's members, and
  /// an empty one to anyone else who may read the event (backend#560). This
  /// gate deliberately consults only the roster for now, though
  /// `household_members` is cached in the same database, so everyone the
  /// roster doesn't name reads it empty, as the server's empty roster reads.
  /// That includes a household member who doesn't attend, and staff, who
  /// read every roster on the server through `read:public_content`. #567
  /// widens it.
  Expression<bool> _readableAttendee($EventAttendeesTableTable t) {
    final me = _db.alias(_db.eventAttendeesTable, 'me');
    return t.eventId.isInQuery(
      _db.selectOnly(me)
        ..addColumns([me.eventId])
        ..where(me.userId.equals(_userId)),
    );
  }

  @override
  Future<EventSnapshot?> getEvent(String id) async {
    checkNotDisposed();
    // One transaction, so a write landing between these reads can't pair an
    // event from one snapshot with occurrences or a roster from another.
    return _db.transaction(() => _readSnapshot(id));
  }

  /// [getEvent]'s reads, for the caller's transaction: they are several
  /// queries, and only one transaction keeps them to one state of the cache.
  Future<EventSnapshot?> _readSnapshot(String id) async {
    final event = await (_db.select(
      _db.eventsTable,
    )..where((t) => t.id.equals(id) & _readableEvent(t))).getSingleOrNull();
    if (event == null) return null;

    // The detail read's order. `createdAt` is compared as an instant, as
    // [_purgeableAttendance] explains.
    final occurrences =
        await (_db.select(_db.eventOccurrencesTable)
              ..where((t) => t.eventId.equals(id))
              ..orderBy([
                (t) => OrderingTerm.asc(t.sortOrder),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    final attendees =
        await (_db.select(_db.eventAttendeesTable)
              ..where((t) => t.eventId.equals(id) & _readableAttendee(t))
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt.julianday),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    final policy = await (_db.select(
      _db.eventPoliciesTable,
    )..where((t) => t.eventId.equals(id))).getSingleOrNull();

    // The snapshot's three states: the roster for a user on it, empty for
    // one it doesn't name, and null where no read has cached one.
    final List<EventAttendee>? roster;
    if (attendees.isNotEmpty) {
      roster = attendees.map(_mapAttendee).toList();
    } else {
      roster = await _hasRoster(id) ? const [] : null;
    }

    return EventSnapshot(
      event: _mapEvent(event),
      occurrences: occurrences.map(_mapOccurrence).toList(),
      policy: policy == null ? null : _mapPolicy(policy),
      attendees: roster,
    );
  }

  /// Whether a roster is cached for [eventId], whoever is on it.
  Future<bool> _hasRoster(String eventId) async {
    final t = _db.eventAttendeesTable;
    final anyRow = _db.selectOnly(t)
      ..addColumns([t.id])
      ..where(t.eventId.equals(eventId))
      ..limit(1);
    return await anyRow.getSingleOrNull() != null;
  }

  @override
  Future<EventAttendee?> getCurrentUserAttendance(String eventId) async {
    checkNotDisposed();
    final row =
        await (_db.select(_db.eventAttendeesTable)..where(
              (t) =>
                  t.eventId.equals(eventId) &
                  t.userId.equals(_userId) &
                  t.eventId.isInQuery(_accessedEventIds()),
            ))
            .getSingleOrNull();
    return row == null ? null : _mapAttendee(row);
  }

  /// Re-reads the event whenever a table [getEvent] reads from changes, or
  /// the access that makes it readable does (#498).
  ///
  /// The event is several queries over five tables, so the stream is a
  /// trigger and a read, not one query for Drift to follow: a constant select
  /// that declares the tables it stands for, so Drift emits on listen and
  /// after any write to them, and each emission re-reads the detail in one
  /// transaction. [awaitedOnDispose] holds disposal back for a read under
  /// way, whose database would otherwise close beneath it. A write to those
  /// tables re-reads whichever event it was for, and `distinct` drops the
  /// reads that found nothing changed here. Drift tells a stream which tables
  /// a write touched, not which rows, so a single joined query would re-run
  /// as often; this costs a few indexed lookups per committed write.
  @override
  Stream<EventDetail?> watchEvent(String id) => untilDisposed(
    () => _db
        .customSelect(
          'SELECT 1',
          readsFrom: {
            _db.eventsTable,
            _db.eventOccurrencesTable,
            _db.eventAttendeesTable,
            _db.eventPoliciesTable,
            _db.eventAccessTable,
          },
        )
        .watch()
        .asyncMap((_) => awaitedOnDispose(_readDetail(id)))
        .distinct(),
  );

  /// The event and the user's own row on its roster, as [getEvent] and
  /// [getCurrentUserAttendance] answer them.
  ///
  /// The row is the snapshot's own: a roster is read only by a user it
  /// names, so it holds theirs wherever one is cached, and one state of the
  /// cache gives both.
  Future<EventDetail?> _readDetail(String id) async {
    final snapshot = await _db.transaction(() => _readSnapshot(id));
    if (snapshot == null) return null;
    return EventDetail(
      snapshot: snapshot,
      attendance: snapshot.attendees
          ?.where((attendee) => attendee.userId == _userId)
          .firstOrNull,
    );
  }

  @override
  Stream<List<Event>> watchAttendingEvents() => untilDisposed(
    () =>
        (_db.select(_db.eventsTable)
              ..where(
                (t) => t.id.isInQuery(
                  _accessedEventIds(eventAccessSourceAttending),
                ),
              )
              // The list's order, `createdAt` compared as an instant, as
              // [_purgeableAttendance] explains.
              ..orderBy([
                (t) => OrderingTerm.desc(t.createdAt.julianday),
                (t) => OrderingTerm.desc(t.id),
              ]))
            .watch()
            .map((rows) => rows.map(_mapEvent).toList()),
  );

  /// One query joining each attending event to its occurrences and this
  /// user's own attendee row, so Drift re-runs it when any of them changes
  /// (#497), as `watchCollectionListItems` does for the collection.
  ///
  /// Left outer joins: an event can have no occurrences, and most have no
  /// cached roster. The attendee join matches on this user, so another
  /// user's row on a shared roster never joins. The server holds one row per
  /// user per event, and a roster is replaced wholesale, so it joins at most
  /// one row and the occurrences are not repeated.
  @override
  Stream<List<EventListItem>> watchAttendingEventListItems() => untilDisposed(
    () {
      final events = _db.eventsTable;
      final occurrences = _db.eventOccurrencesTable;
      final mine = _db.alias(_db.eventAttendeesTable, 'own_attendance');

      final query =
          _db.select(events).join([
              leftOuterJoin(
                occurrences,
                occurrences.eventId.equalsExp(events.id),
              ),
              leftOuterJoin(
                mine,
                mine.eventId.equalsExp(events.id) & mine.userId.equals(_userId),
              ),
            ])
            ..where(
              events.id.isInQuery(
                _accessedEventIds(eventAccessSourceAttending),
              ),
            )
            // [watchAttendingEvents]'s order, then the detail read's order
            // within each event.
            ..orderBy([
              OrderingTerm.desc(events.createdAt.julianday),
              OrderingTerm.desc(events.id),
              OrderingTerm.asc(occurrences.sortOrder),
              OrderingTerm.asc(occurrences.id),
            ]);

      return query.watch().map((rows) {
        // One row per occurrence, so each event's rows fold into one item.
        // A map keeps the events in the order they came.
        final rowsByEvent = <String, List<TypedResult>>{};
        for (final row in rows) {
          rowsByEvent.putIfAbsent(row.readTable(events).id, () => []).add(row);
        }
        return [
          for (final eventRows in rowsByEvent.values)
            EventListItem(
              event: _mapEvent(eventRows.first.readTable(events)),
              occurrences: [
                for (final row in eventRows)
                  if (row.readTableOrNull(occurrences) case final o?)
                    _mapOccurrence(o),
              ],
              // The same on every row of the event.
              attendance: switch (eventRows.first.readTableOrNull(mine)) {
                final row? => _mapAttendee(row),
                null => null,
              },
            ),
        ];
      });
    },
  );

  // ── Mappers ────────────────────────────────────────────────────────────

  static String _encodeSource(EventAccessSource source) => switch (source) {
    EventAccessSource.attending => eventAccessSourceAttending,
    EventAccessSource.read => eventAccessSourceRead,
  };

  /// The name an enum column stores for [value]: its wire name, or
  /// [_unknownName] for [unknown], which stands for a name this client could
  /// not read and so has no wire name of its own. The name the server sent
  /// is not kept.
  static String _encode<T extends Enum>(
    T value,
    T unknown,
    String Function(T) toWire,
  ) => value == unknown ? _unknownName : toWire(value);

  Event _mapEvent(EventsTableData row) => Event(
    id: row.id,
    title: row.title,
    createdById: row.createdById,
    householdId: row.householdId,
    description: row.description,
    image: row.image,
    location: row.location,
    url: row.url,
    type: EventType.fromWire(row.type),
    reach: Reach.fromWire(row.reach),
    status: EventStatus.fromWire(row.status),
    schedulingMode: EventSchedulingMode.fromWire(row.schedulingMode),
    isDirty: row.isDirty,
    isLocalOnly: row.isLocalOnly,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  /// The server's copy of [e]: every column but the two sync flags. Left
  /// absent, an insert takes their defaults and an update keeps what a local
  /// writer set, since a server copy carries no local sync state (#298's
  /// rule for households). The model's own flags are never written.
  EventsTableCompanion _eventToCompanion(Event e) =>
      EventsTableCompanion.insert(
        id: e.id,
        title: e.title,
        createdById: e.createdById,
        householdId: Value(e.householdId),
        description: Value(e.description),
        image: Value(e.image),
        location: Value(e.location),
        url: Value(e.url),
        type: _encode(e.type, EventType.unknown, (v) => v.toWire()),
        reach: _encode(e.reach, Reach.unknown, (v) => v.toWire()),
        status: _encode(e.status, EventStatus.unknown, (v) => v.toWire()),
        schedulingMode: _encode(
          e.schedulingMode,
          EventSchedulingMode.unknown,
          (v) => v.toWire(),
        ),
        createdAt: e.createdAt,
        updatedAt: e.updatedAt,
      );

  EventOccurrence _mapOccurrence(EventOccurrencesTableData row) =>
      EventOccurrence(
        id: row.id,
        eventId: row.eventId,
        label: row.label,
        startDate: row.startDate,
        endDate: row.endDate,
        location: row.location,
        status: OccurrenceStatus.fromWire(row.status),
        sortOrder: row.sortOrder,
        confirmedAt: row.confirmedAt,
        declinedAt: row.declinedAt,
        cancelledAt: row.cancelledAt,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
      );

  EventOccurrencesTableCompanion _occurrenceToCompanion(EventOccurrence o) =>
      EventOccurrencesTableCompanion.insert(
        id: o.id,
        eventId: o.eventId,
        label: Value(o.label),
        startDate: Value(o.startDate),
        endDate: Value(o.endDate),
        location: Value(o.location),
        status: _encode(o.status, OccurrenceStatus.unknown, (v) => v.toWire()),
        sortOrder: o.sortOrder,
        confirmedAt: Value(o.confirmedAt),
        declinedAt: Value(o.declinedAt),
        cancelledAt: Value(o.cancelledAt),
        createdAt: o.createdAt,
        updatedAt: o.updatedAt,
      );

  EventAttendee _mapAttendee(EventAttendeesTableData row) => EventAttendee(
    id: row.id,
    eventId: row.eventId,
    userId: row.userId,
    guestName: row.guestName,
    username: row.username,
    displayName: row.displayName,
    avatarUrl: row.avatarUrl,
    notes: row.notes,
    status: EventParticipationStatus.fromWire(row.status),
    role: row.roleName == null ? null : EventRole.fromWire(row.roleName!),
    rsvpDate: row.rsvpDate,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  EventAttendeesTableCompanion _attendeeToCompanion(EventAttendee a) {
    final role = a.role;
    return EventAttendeesTableCompanion.insert(
      id: a.id,
      eventId: a.eventId,
      userId: Value(a.userId),
      guestName: Value(a.guestName),
      username: Value(a.username),
      displayName: Value(a.displayName),
      avatarUrl: Value(a.avatarUrl),
      notes: Value(a.notes),
      status: _encode(
        a.status,
        EventParticipationStatus.unknown,
        (v) => v.toWire(),
      ),
      roleName: Value(
        role == null
            ? null
            : _encode(role, EventRole.unknown, (v) => v.toWire()),
      ),
      rsvpDate: Value(a.rsvpDate),
      createdAt: a.createdAt,
      updatedAt: a.updatedAt,
    );
  }

  EventPolicy _mapPolicy(EventPoliciesTableData row) => EventPolicy(
    id: row.id,
    eventId: row.eventId,
    allowMemberInvites: row.allowMemberInvites,
    allowGuestInvites: row.allowGuestInvites,
    maxAttendees: row.maxAttendees,
    restrictToGameCategories: row.restrictToGameCategories,
    requireHostApprovalToJoin: row.requireHostApprovalToJoin,
    allowSpectators: row.allowSpectators,
    maxTotalParticipants: row.maxTotalParticipants,
    strictCapacity: row.strictCapacity,
    gameAdditionMode: GameAdditionMode.fromWire(row.gameAdditionMode),
    restrictToAttendeePool: row.restrictToAttendeePool,
    fillerMaxPlayTime: row.fillerMaxPlayTime,
    voteThresholdType: VoteThresholdType.fromWire(row.voteThresholdType),
    voteThresholdValue: row.voteThresholdValue,
    voteQuorumType: VoteQuorumType.fromWire(row.voteQuorumType),
    voteQuorumValue: row.voteQuorumValue,
    voteEligibility: VoteEligibility.fromWire(row.voteEligibility),
    interestedWeight: InterestedWeight.fromWire(row.interestedWeight),
    votingWindowHours: row.votingWindowHours,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  EventPoliciesTableCompanion _policyToCompanion(EventPolicy p) =>
      EventPoliciesTableCompanion.insert(
        id: p.id,
        eventId: p.eventId,
        allowMemberInvites: p.allowMemberInvites,
        allowGuestInvites: p.allowGuestInvites,
        maxAttendees: Value(p.maxAttendees),
        restrictToGameCategories: p.restrictToGameCategories,
        requireHostApprovalToJoin: p.requireHostApprovalToJoin,
        allowSpectators: p.allowSpectators,
        maxTotalParticipants: Value(p.maxTotalParticipants),
        strictCapacity: p.strictCapacity,
        gameAdditionMode: _encode(
          p.gameAdditionMode,
          GameAdditionMode.unknown,
          (v) => v.toWire(),
        ),
        restrictToAttendeePool: p.restrictToAttendeePool,
        fillerMaxPlayTime: Value(p.fillerMaxPlayTime),
        voteThresholdType: _encode(
          p.voteThresholdType,
          VoteThresholdType.unknown,
          (v) => v.toWire(),
        ),
        voteThresholdValue: Value(p.voteThresholdValue),
        voteQuorumType: _encode(
          p.voteQuorumType,
          VoteQuorumType.unknown,
          (v) => v.toWire(),
        ),
        voteQuorumValue: Value(p.voteQuorumValue),
        voteEligibility: _encode(
          p.voteEligibility,
          VoteEligibility.unknown,
          (v) => v.toWire(),
        ),
        interestedWeight: _encode(
          p.interestedWeight,
          InterestedWeight.unknown,
          (v) => v.toWire(),
        ),
        votingWindowHours: Value(p.votingWindowHours),
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
      );
}
