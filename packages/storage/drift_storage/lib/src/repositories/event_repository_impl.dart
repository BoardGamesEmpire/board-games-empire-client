import 'package:cuid2/cuid2.dart';
import 'package:drift/drift.dart';
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/stored_enum_name.dart';
import 'package:drift_storage/src/repositories/watch_disposal.dart';
import 'package:drift_storage/src/tables/event_access_table.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

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
/// is narrower still: [getEvent] serves it only to a user it names, or one
/// whose own detail read the server showed it to (#567).
///
/// The user is fixed at construction, as `GameRepositoryImpl`'s is. A page
/// the hydrate writes after its session has ended, before the scope finishes
/// popping, still records its events for the user they came from. No method
/// takes a user id.
///
/// ## The queued create (#499)
///
/// [create] is the one local write. In one transaction it writes the event
/// with `isLocalOnly` and `isDirty` set, its dates, the creator's row on its
/// roster and their `attending` access, and enqueues the op. The flags hand
/// the event to the sync queue: a read writes nothing of it, and no purge,
/// [forgetEvent] or [removeDeletedEvent] removes it. [reconcileCreatedEvent]
/// deletes it, writes the server's copy in its place by a read's rules, and
/// records in `event_moves` where it went, for [reconciledEventId].
///
/// ## Disposal
///
/// Registered in the user-session scope, which pops on sign-out, a server
/// switch, suspend and context dispose. Its Drift stream is tied to the
/// per-server database, which outlives that scope, so it takes the shared
/// [WatchDisposal] contract (#138): after `onDispose()` the `Future` methods
/// throw [StateError], and [watchAttendingEvents] and [watchEvent] close.
/// [reconciledEventId] still answers.
class EventRepositoryImpl with WatchDisposal implements EventRepository {
  /// [_syncQueue] must be over this same [_db], as `HouseholdRepositoryImpl`'s
  /// is, for [create]'s one transaction to hold: the enqueue joins the
  /// transaction only when it writes to the same database. Over another, it
  /// would commit apart from the event, which a failure could then leave
  /// without its op, and no test would catch it. `UserSessionScopeInstaller`
  /// wires the session's queue, over this scope's database.
  EventRepositoryImpl(
    this._db, {
    required this._userId,
    required this._syncQueue,
    required this._clock,
  });

  final ServerDatabase _db;
  final String _userId;
  final SyncQueueRepository _syncQueue;

  /// Server-corrected time (#12), for the timestamps [create] writes, as the
  /// queue's own are.
  final ClockService _clock;

  /// Local id to the server's, for every move this repository has recorded
  /// or read from `event_moves` ([reconciledEventId]). Never shrinks: a move
  /// is never undone.
  final Map<String, String> _moves = {};

  /// The access sources whose rows keep the user's own answer: the two lists
  /// that carry one (#667, #503). Every write of an answer goes on both, where
  /// the rows exist, so a list item reads the same answer from either.
  static const List<String> _answerSources = [
    eventAccessSourceAttending,
    eventAccessSourceHousehold,
  ];

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
  /// [EventRepository.cacheEvent] lists, for every snapshot at once, except
  /// for an event that is `isDirty` or `isLocalOnly`.
  ///
  /// That event belongs to the sync queue until the server acknowledges it,
  /// as #298 has it for households: a server copy written over it would undo
  /// what the queue is about to send, or replace an event the server has not
  /// seen. It gets no upsert, no generation, no children and no access row,
  /// and the events beside it in the page are written as usual.
  ///
  /// One transaction, so the flags are read in the state the write sees. It
  /// also joins the caller's, where there is one, as Drift nests it in a
  /// savepoint.
  Future<void> _writeSnapshots(
    List<EventSnapshot> snapshots,
    EventAccessSource source,
  ) async {
    // An event named twice is written from its later snapshot alone, so its
    // occurrences and roster aren't inserted twice.
    final named = {for (final s in snapshots) s.event.id: s};
    if (named.isEmpty) return;

    await _db.transaction(() async {
      final owned = await _queueOwnedIds(named.keys);
      final byId = {
        for (final entry in named.entries)
          if (!owned.contains(entry.key)) entry.key: entry.value,
      };
      if (byId.isEmpty) return;
      await _writeBatch(byId, source);
    });
  }

  /// Gives each of [eventIds] the next generation, in [b], after the batch
  /// has written them.
  ///
  /// Every write takes one, so a purge that read the events before it can
  /// tell it happened. From the shared counter, not the event's own row,
  /// which a purge may have deleted since: a row counted afresh would repeat
  /// the deleted one's.
  void _stampGeneration(Batch b, Iterable<String> eventIds) {
    final counter = _db.eventGenerationTable;
    b
      ..insert(
        counter,
        const EventGenerationTableCompanion(
          id: Value(0),
          lastGeneration: Value(1),
        ),
        onConflict:
            DoUpdate<$EventGenerationTableTable, EventGenerationTableData>(
              (old) => EventGenerationTableCompanion.custom(
                lastGeneration: old.lastGeneration + const Constant(1),
              ),
            ),
      )
      ..update(
        _db.eventsTable,
        EventsTableCompanion.custom(
          generation: subqueryExpression<int>(
            _db.selectOnly(counter)..addColumns([counter.lastGeneration]),
          ),
        ),
        where: (t) => t.id.isIn(eventIds),
      );
  }

  /// Which of [eventIds] are cached with local changes the server has not
  /// acknowledged: `isDirty` or `isLocalOnly`.
  Future<Set<String>> _queueOwnedIds(Iterable<String> eventIds) async {
    final t = _db.eventsTable;
    final query = _db.selectOnly(t)
      ..addColumns([t.id])
      ..where(t.id.isIn(eventIds) & (t.isDirty | t.isLocalOnly));
    return {for (final row in await query.get()) row.read(t.id)!};
  }

  /// Writes [byId], none of them queue-owned, as one batch, so it is one round
  /// trip, which on web is one message to the database worker rather than
  /// several per event. Drift tells a live query about the page once because
  /// [_writeSnapshots] holds the transaction open around it.
  Future<void> _writeBatch(
    Map<String, EventSnapshot> byId,
    EventAccessSource source,
  ) async {
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
      _stampGeneration(b, byId.keys);

      // A snapshot without a policy says nothing about the cached one: a
      // read serves none to a caller its own check refuses, and the server
      // has no policy delete.
      b
        ..insertAllOnConflictUpdate(_db.eventPoliciesTable, [
          for (final s in written)
            if (s.policy case final policy?) _policyToCompanion(policy),
        ])
        // Every read, list, detail or household, carries all of an event's
        // occurrences, and the server hard-deletes one, so an empty list
        // clears them.
        ..deleteWhere(
          _db.eventOccurrencesTable,
          (t) => t.eventId.isIn(byId.keys),
        )
        ..insertAll(_db.eventOccurrencesTable, [
          for (final s in written) ...s.occurrences.map(_occurrenceToCompanion),
        ]);

      if (rosters.isNotEmpty) {
        b
          ..deleteWhere(
            _db.eventAttendeesTable,
            (t) => t.eventId.isIn(rosters.keys),
          )
          ..insertAll(_db.eventAttendeesTable, [
            for (final roster in rosters.values)
              ...roster.map(_attendeeToCompanion),
          ]);
        // The roster is shared by every user on this device, so it replaces
        // other users' rows too, and is the newer news for their answers. Each
        // goes on that user's `attending` and `household` rows, where they
        // have them, so their lists don't show what they said before. This
        // user's comes from the read's own answer, below. A user the roster
        // leaves off keeps theirs: a roster is read under the reader's
        // ceiling, so it doesn't say they left.
        for (final MapEntry(key: eventId, value: roster) in rosters.entries) {
          for (final attendee in roster) {
            final userId = attendee.userId;
            if (userId == null || userId == _userId) continue;
            b.update(
              _db.eventAccessTable,
              _answerToCompanion(EventAttendance.fromAttendee(attendee)),
              where: (t) =>
                  t.userId.equals(userId) &
                  t.eventId.equals(eventId) &
                  t.source.isIn(_answerSources),
            );
          }
        }
      }
      if (refused.isNotEmpty) {
        b.deleteWhere(
          _db.eventAttendeesTable,
          (t) => t.eventId.isIn(refused) & t.userId.equals(_userId),
        );
      }
      // A list row carries no roster, only the user's own answer, which is
      // newer than a cached roster's copy of it. So it updates their row in
      // place, matched by attendee id and by user, and adds none: one row on
      // an event with no roster cached would read as a roster of one (#667).
      for (final s in written) {
        if ((s.attendees, s.attendance) case (null, final attendance?)) {
          b.update(
            _db.eventAttendeesTable,
            EventAttendeesTableCompanion(
              status: Value(_statusName(attendance.status)),
              roleName: Value(_roleName(attendance.role)),
              rsvpDate: Value(attendance.rsvpDate),
            ),
            where: (t) =>
                t.id.equals(attendance.attendeeId) &
                t.eventId.equals(s.event.id) &
                t.userId.equals(_userId),
          );
        }
      }

      switch (source) {
        // The list speaks for the user's own attendance, so its answer goes
        // on their `attending` row, null included, over whatever an earlier
        // read left there: the last write wins (#667, #589).
        case EventAccessSource.attending:
          b.insertAll(
            _db.eventAccessTable,
            [
              for (final s in written)
                _answerToCompanion(s.attendance).copyWith(
                  userId: Value(_userId),
                  eventId: Value(s.event.id),
                  source: const Value(eventAccessSourceAttending),
                ),
            ],
            onConflict:
                DoUpdate<
                  $EventAccessTableTable,
                  EventAccessTableData
                >.withExcluded(
                  (_, excluded) => EventAccessTableCompanion.custom(
                    attendeeId: excluded.attendeeId,
                    attendanceStatus: excluded.attendanceStatus,
                    attendanceRole: excluded.attendanceRole,
                    rsvpDate: excluded.rsvpDate,
                  ),
                ),
          );
          // And onto the user's `household` row, where there is one, so the
          // household's list doesn't show an answer this list replaced.
          for (final s in written) {
            b.update(
              _db.eventAccessTable,
              _answerToCompanion(s.attendance),
              where: (t) =>
                  t.userId.equals(_userId) &
                  t.eventId.equals(s.event.id) &
                  t.source.equals(eventAccessSourceHousehold),
            );
          }
        // A detail read speaks for what the user may read, not for their
        // list, so it adds no `attending` row. But its answer is as new as a
        // list row's, and goes on the rows the lists wrote, where there are
        // any, null included: the server sends none for a user who left or
        // was removed, and a list item reading an answer kept from before
        // would go on showing it. Cleared, the item falls back to the roster
        // this same read wrote.
        //
        // A household's list is the same kind of read for this: it adds its
        // own `household` row, and no `attending` one (#503). Its answer goes
        // on both, so the household's item has one where the attending list
        // has yet to write the event, as after a failed hydrate.
        case EventAccessSource.read || EventAccessSource.household:
          final name = switch (source) {
            EventAccessSource.household => eventAccessSourceHousehold,
            _ => eventAccessSourceRead,
          };
          b.insertAll(_db.eventAccessTable, [
            for (final eventId in byId.keys)
              EventAccessTableCompanion.insert(
                userId: _userId,
                eventId: eventId,
                source: name,
              ),
          ], mode: InsertMode.insertOrIgnore);
          for (final s in written) {
            b.update(
              _db.eventAccessTable,
              _answerToCompanion(s.attendance),
              where: (t) =>
                  t.userId.equals(_userId) &
                  t.eventId.equals(s.event.id) &
                  t.source.isIn(_answerSources),
            );
          }
          // `GET /events/:id` reads the caller's own row apart from the
          // roster, so a null `attendance` is the server saying this user
          // isn't attending, whatever the roster says: a roster is read under
          // the reader's ceiling and can't say it. The event leaves their
          // attending list, as the next hydrate's purge would take it; the
          // `read` and `household` rows stay (#752).
          if (source == EventAccessSource.read) {
            final notAttending = [
              for (final s in written)
                if (s.attendance == null) s.event.id,
            ];
            if (notAttending.isNotEmpty) {
              b.deleteWhere(
                _db.eventAccessTable,
                (t) =>
                    t.userId.equals(_userId) &
                    t.source.equals(eventAccessSourceAttending) &
                    t.eventId.isIn(notAttending),
              );
            }
          }
          // Whether the server showed this user the roster is a fact about
          // their detail read alone. A household's list row carries
          // `attendees: null`, which says nothing either way, so it leaves
          // the flag as it was (#567).
          if (source == EventAccessSource.read) {
            if (rosters.isNotEmpty) {
              b.update(
                _db.eventAccessTable,
                const EventAccessTableCompanion(rosterShown: Value(true)),
                where: (t) =>
                    t.userId.equals(_userId) &
                    t.source.equals(eventAccessSourceRead) &
                    t.eventId.isIn(rosters.keys),
              );
            }
            if (refused.isNotEmpty) {
              b.update(
                _db.eventAccessTable,
                const EventAccessTableCompanion(rosterShown: Value(false)),
                where: (t) =>
                    t.userId.equals(_userId) &
                    t.source.equals(eventAccessSourceRead) &
                    t.eventId.isIn(refused),
              );
            }
          }
      }
    });
  }

  // ── The queued create (#499) ───────────────────────────────────────────

  @override
  Future<({Event event, String syncQueueId, CreateEventOperation operation})>
  create(EventDraft draft) async {
    checkNotDisposed();
    // Before the transaction, so a draft the server would refuse leaves the
    // cache and the queue untouched.
    final title = draft.title.trim();
    _checkDraft(draft, title);

    return _db.transaction(() async {
      // Inside, so the household's move and its local row are read in one
      // state: a reconcile committed between the two reads would leave
      // neither, and the obsolete local id would be sent.
      final householdId = switch (draft.householdId) {
        final id? => await _sendableHousehold(id),
        null => null,
      };
      final now = _clock.nowUtc();
      // The event's id until the reconcile replaces it with the server's,
      // and the create's idempotency key, so minted once, here.
      final localId = cuid();
      // The server's own rules for a new event's status and dates.
      final poll = draft.schedulingMode == EventSchedulingMode.poll;

      await _db.batch((b) {
        // The type and reach the server defaults to where the draft leaves
        // them out.
        b
          ..insert(
            _db.eventsTable,
            EventsTableCompanion.insert(
              id: localId,
              title: title,
              createdById: _userId,
              householdId: Value(householdId),
              description: Value(draft.description),
              location: Value(draft.location),
              url: Value(draft.url),
              type: (draft.type ?? EventType.casualGathering).toWire(),
              reach: (draft.reach ?? Reach.friends).toWire(),
              status: (poll ? EventStatus.planning : EventStatus.scheduled)
                  .toWire(),
              schedulingMode: draft.schedulingMode.toWire(),
              isDirty: const Value(true),
              isLocalOnly: const Value(true),
              createdAt: now,
              updatedAt: now,
            ),
          )
          ..insertAll(_db.eventOccurrencesTable, [
            for (final (index, occurrence) in draft.occurrences.indexed)
              EventOccurrencesTableCompanion.insert(
                id: cuid(),
                eventId: localId,
                label: Value(occurrence.label),
                startDate: Value(occurrence.startDate?.toUtc()),
                endDate: Value(occurrence.endDate?.toUtc()),
                location: Value(occurrence.location),
                status:
                    (poll
                            ? OccurrenceStatus.proposed
                            : OccurrenceStatus.confirmed)
                        .toWire(),
                sortOrder: index,
                confirmedAt: Value(poll ? null : now),
                createdAt: now,
                updatedAt: now,
              ),
          ])
          // The server makes the creator its host, and this row makes the
          // event read as theirs at once, on the overview and in its detail.
          ..insert(
            _db.eventAttendeesTable,
            EventAttendeesTableCompanion.insert(
              id: cuid(),
              eventId: localId,
              userId: Value(_userId),
              status: EventParticipationStatus.attending.toWire(),
              roleName: Value(EventRole.host.toWire()),
              createdAt: now,
              updatedAt: now,
            ),
          )
          ..insert(
            _db.eventAccessTable,
            EventAccessTableCompanion.insert(
              userId: _userId,
              eventId: localId,
              source: eventAccessSourceAttending,
            ),
          );
        _stampGeneration(b, [localId]);
      });

      // If this throws, the writes above roll back.
      final operation = CreateEventOperation(
        localId: localId,
        draft: draft.copyWith(title: title, householdId: householdId),
      );
      final entry = await _syncQueue.enqueue(operation);

      final row = await (_db.select(
        _db.eventsTable,
      )..where((t) => t.id.equals(localId))).getSingle();
      return (
        event: _mapEvent(row),
        syncQueueId: entry.id,
        operation: operation,
      );
    });
  }

  /// Throws [ArgumentError] for a draft the server is sure to refuse with a
  /// 400, given [title], its title trimmed. A queued create the server
  /// refuses is parked on its first attempt, so the caller hears of it here
  /// instead.
  static void _checkDraft(EventDraft draft, String title) {
    if (title.isEmpty) {
      throw ArgumentError.value(
        draft.title,
        'draft.title',
        'must not be blank',
      );
    }
    if (draft.schedulingMode == EventSchedulingMode.fixed &&
        draft.occurrences.length > 1) {
      throw ArgumentError.value(
        draft.occurrences.length,
        'draft.occurrences',
        'a Fixed event takes at most one date',
      );
    }
    draft.checkSendable();
  }

  /// The id to send for [householdId]: the server's, where the household was
  /// created on this device and its create has landed since, as when it
  /// lands while the form is open. Either way an id the server has never
  /// heard of would be refused with a 404.
  ///
  /// Throws [ArgumentError] when [householdId] names a household created on
  /// this device that the server has yet to confirm. Run inside the create's
  /// transaction, before its writes.
  Future<String> _sendableHousehold(String householdId) async {
    final moves = _db.householdMovesTable;
    final moved =
        await (_db.selectOnly(moves)
              ..addColumns([moves.serverId])
              ..where(moves.localId.equals(householdId)))
            .getSingleOrNull();
    if (moved != null) return moved.read(moves.serverId)!;

    final t = _db.householdsTable;
    final localOnly = _db.selectOnly(t)
      ..addColumns([t.id])
      ..where(t.id.equals(householdId) & t.isLocalOnly.equals(true));
    if (await localOnly.getSingleOrNull() != null) {
      throw ArgumentError.value(
        householdId,
        'draft.householdId',
        'names a household the server has yet to confirm',
      );
    }
    return householdId;
  }

  @override
  Future<void> reconcileCreatedEvent(
    EventSnapshot server, {
    required String localId,
    required bool deleted,
    String? completedSyncQueueId,
  }) async {
    checkNotDisposed();
    final serverId = server.event.id;
    // Not where the server kept the local id: a move to itself would have a
    // screen that follows moves follow it forever.
    final moved = !deleted && serverId != localId;

    await _db.transaction(() async {
      // 1. The local event goes first, even where the server kept its id: a
      //    read writes nothing of an event the queue owns, so the server's
      //    copy could not be written over it.
      await _deleteLocalOnly(localId);

      // 2. The server's copy, by a read's rules: a copy a hydrate cached
      //    first is written over, and a replay's empty roster or missing
      //    policy says what it says there. Then where the event went,
      //    committed with the deletion so no reader finds one without the
      //    other, in this tab or another. A second reconcile of the same
      //    local id replaces it. A deleted event's copy goes instead.
      if (deleted) {
        await _deleteServerCopy(serverId);
      } else {
        final roster = server.attendees;
        // Attended, unless the roster leaves the creator off: a repeat
        // answers as they may read the event now, which may be after they
        // left it, or lost read on it. Kept apart from the attended events,
        // as a read's, it still answers a screen following the move.
        final attends =
            roster == null || roster.any((a) => a.userId == _userId);
        await _writeSnapshots([
          if (roster == null)
            server
          else
            server.copyWith(attendees: await _keepCachedNames(roster)),
        ], attends ? EventAccessSource.attending : EventAccessSource.read);
        // A hydrate may have cached it as attended before they left. The
        // repeat is the newer news, and takes that attendance back as the
        // next purge would.
        if (!attends) {
          await (_db.delete(_db.eventAccessTable)..where(
                (t) =>
                    t.userId.equals(_userId) &
                    t.eventId.equals(serverId) &
                    t.source.equals(eventAccessSourceAttending),
              ))
              .go();
        }
        if (moved) {
          await _db
              .into(_db.eventMovesTable)
              .insertOnConflictUpdate(
                EventMovesTableCompanion.insert(
                  localId: localId,
                  serverId: serverId,
                ),
              );
        }
      }

      // 3. The queued op closes with it, when the caller knows which it was.
      if (completedSyncQueueId != null) {
        await _syncQueue.markCompleted(completedSyncQueueId);
      }
    });
    // So a caller here can ask at once, without waiting on an emission to
    // read the move back.
    if (moved) _moves[localId] = serverId;
  }

  @override
  String? reconciledEventId(String localId) => _moves[localId];

  @override
  Future<bool> discardQueuedOp(String syncQueueId) async {
    checkNotDisposed();
    return _db.transaction(() async {
      final entry = await _syncQueue.getEntry(syncQueueId);
      if (entry == null) return false;

      SyncOperation? op;
      try {
        op = entry.operation;
      } on Object {
        op = null;
      }
      if (op != null && op is! CreateEventOperation) {
        throw ArgumentError.value(
          syncQueueId,
          'syncQueueId',
          'names a collection or household op; their own repositories '
              'discard those',
        );
      }
      final localId = switch (op) {
        CreateEventOperation(:final localId) => localId,
        // A create a newer build queued, with a name this one can't read,
        // still names its local event, which nothing else would remove: no
        // read, purge or reconcile touches a local-only event. Anything else
        // that won't decode left nothing here to undo.
        _ => CreateEventOperation.localIdOf(entry.payload),
      };
      // Checked in the statement that deletes it: a create another tab
      // retried since may be on its way to the server.
      if (!await _syncQueue.discardStuck(entry.id)) return false;

      if (localId != null) await _deleteLocalOnly(localId);
      return true;
    });
  }

  /// Deletes the event [localId] with its occurrences, roster, policy and
  /// every user's access to it, while it is `isLocalOnly`: an event [create]
  /// wrote that the server has not confirmed. Anything else cached under
  /// that id stays. Run inside the caller's transaction.
  Future<void> _deleteLocalOnly(String localId) async {
    final t = _db.eventsTable;
    final localOnly = _db.selectOnly(t)
      ..addColumns([t.id])
      ..where(t.id.equals(localId) & t.isLocalOnly.equals(true));
    await (_db.delete(
      _db.eventAccessTable,
    )..where((a) => a.eventId.isInQuery(localOnly))).go();
    await _deleteUnreachable({localId});
  }

  /// Deletes the cached event [id] with its occurrences, roster, policy and
  /// every user's access to it, unless the sync queue owns it: an event the
  /// server says it deleted, which no user's read survives. Run inside the
  /// caller's transaction.
  Future<void> _deleteServerCopy(String id) async {
    if ((await _queueOwnedIds([id])).isNotEmpty) return;
    await (_db.delete(
      _db.eventAccessTable,
    )..where((a) => a.eventId.equals(id))).go();
    await _deleteUnreachable({id});
  }

  /// [roster], a create's answer, with each account's name and avatar taken
  /// from the row cached for the same attendee, where one is. Run inside the
  /// reconcile's transaction.
  ///
  /// The answer embeds each attendee's role and not their user, so every
  /// name in it is null. Written as it is, it would blank a named roster a
  /// hydrate or detail read cached under the server's id first, as one does
  /// while a create's lost answer waits on its retry. A name belongs to the
  /// account, which the create doesn't change.
  Future<List<EventAttendee>> _keepCachedNames(
    List<EventAttendee> roster,
  ) async {
    final ids = [
      for (final a in roster)
        if (a.userId != null && a.username == null) a.id,
    ];
    if (ids.isEmpty) return roster;
    final cached = {
      for (final row in await (_db.select(
        _db.eventAttendeesTable,
      )..where((t) => t.id.isIn(ids))).get())
        row.id: row,
    };
    return [
      for (final a in roster)
        switch (cached[a.id]) {
          final row? when row.userId == a.userId && a.username == null =>
            a.copyWith(
              username: row.username,
              displayName: row.displayName,
              avatarUrl: row.avatarUrl,
            ),
          _ => a,
        },
    ];
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
      //
      // And the flag on their `read` row (#567). It can't tell whether the
      // server showed them the roster because they attended, and this purge
      // is the server saying they no longer do, so the cache fails closed on
      // other people's names. The detail screen reads on open, so a user the
      // server still shows it, such as a household member, gets it back from
      // that read. The household purge leaves the flag: a household's list
      // says nothing of the roster.
      await (_db.update(_db.eventAccessTable)..where(
            (t) =>
                t.userId.equals(_userId) &
                t.source.equals(eventAccessSourceRead) &
                t.eventId.isIn(purged),
          ))
          .write(const EventAccessTableCompanion(rosterShown: Value(false)));
      // And the answer on their `household` rows, which the household's
      // list goes on showing them: the list holds every event they answered,
      // so they have no answer on these now. The row stays, as the household
      // still lists the event (#503).
      await (_db.update(_db.eventAccessTable)..where(
            (t) =>
                t.userId.equals(_userId) &
                t.source.equals(eventAccessSourceHousehold) &
                t.eventId.isIn(purged),
          ))
          .write(_answerToCompanion(null));
      await (_db.delete(
        _db.eventAttendeesTable,
      )..where((t) => t.userId.equals(_userId) & t.eventId.isIn(purged))).go();

      await _deleteUnreachable(purged);
      return purged;
    });
  }

  @override
  Future<Map<String, int>> purgeableHouseholdEvents(String householdId) async {
    checkNotDisposed();
    return _purgeableHousehold(householdId);
  }

  @override
  Future<Set<String>> purgeHouseholdEventsAbsentFrom(
    String householdId,
    Set<String> snapshotIds, {
    required Map<String, int> purgeable,
  }) async {
    checkNotDisposed();
    return _db.transaction(() async {
      // Read again, as the attendance purge does: an event in [purgeable] may
      // have been edited or written again since.
      final current = await _purgeableHousehold(householdId);
      final purged = {
        for (final MapEntry(key: id, value: generation) in current.entries)
          if (purgeable[id] == generation && !snapshotIds.contains(id)) id,
      };
      if (purged.isEmpty) return const <String>{};

      // This user's `household` row alone. The household list says nothing
      // of their attendance, so their roster row, and their `attending` and
      // `read` access, stay.
      await (_db.delete(_db.eventAccessTable)..where(
            (t) =>
                t.userId.equals(_userId) &
                t.source.equals(eventAccessSourceHousehold) &
                t.eventId.isIn(purged),
          ))
          .go();

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

      // Every source, where the purge removes `attending` alone. The list
      // speaks for a user's attendance and nothing else, but an event the
      // server refuses this user by id is closed to them by any of the three
      // routes.
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

  @override
  Future<bool> removeDeletedEvent(String id) async {
    checkNotDisposed();
    return _db.transaction(() async {
      // Any user's copy, and with no mark: the server deleted the event for
      // everyone, so it needn't be one this user can read, and nothing
      // written since can say otherwise. The queue still keeps what it
      // owns: a delete never reaches a local-only event, and a dirty one
      // carries an edit the queue has yet to send.
      final cached = await (_db.select(
        _db.eventsTable,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (cached == null || cached.isDirty || cached.isLocalOnly) return false;

      await _deleteServerCopy(id);
      return true;
    });
  }

  @override
  Future<bool> cacheOccurrence(EventOccurrence occurrence) async {
    checkNotDisposed();
    final eventId = occurrence.eventId;
    return _db.transaction(() async {
      // The event row and the queue's mark are checked inside the
      // transaction, which starts after the lock, so they hold for the write.
      if (!await _isCachedAndServerOwned(eventId)) return false;

      await _db
          .into(_db.eventOccurrencesTable)
          .insertOnConflictUpdate(_occurrenceToCompanion(occurrence));
      await _db.batch((b) => _stampGeneration(b, [eventId]));
      return true;
    });
  }

  @override
  Future<bool> cacheAttendee(EventAttendee attendee) async {
    checkNotDisposed();
    final eventId = attendee.eventId;
    return _db.transaction(() async {
      if (!await _isCachedAndServerOwned(eventId)) return false;

      // The roster row with this id, where one is cached. An RSVP answers
      // for a row the server has, but a roster this client never read has no
      // row to replace, and one row alone would read as a roster of one.
      final rosterRows =
          await (_db.update(_db.eventAttendeesTable)..where(
                (t) => t.id.equals(attendee.id) & t.eventId.equals(eventId),
              ))
              .write(
                _attendeeToCompanion(attendee).copyWith(
                  id: const Value.absent(),
                  eventId: const Value.absent(),
                ),
              );

      final answerRows = await _writeOwnAnswer(attendee);

      if (rosterRows == 0 && answerRows == 0) return false;
      await _db.batch((b) => _stampGeneration(b, [eventId]));
      return true;
    });
  }

  @override
  Future<bool> addCachedAttendee(EventAttendee attendee) async {
    checkNotDisposed();
    final eventId = attendee.eventId;
    return _db.transaction(() async {
      if (!await _isCachedAndServerOwned(eventId)) return false;

      // A roster this client never read gets no row: one alone would read as
      // a roster of one.
      final cachedRows = _db.eventAttendeesTable.id.count();
      final count =
          await (_db.selectOnly(_db.eventAttendeesTable)
                ..addColumns([cachedRows])
                ..where(_db.eventAttendeesTable.eventId.equals(eventId)))
              .map((r) => r.read(cachedRows) ?? 0)
              .getSingle();
      if (count == 0) return false;

      await _db
          .into(_db.eventAttendeesTable)
          .insertOnConflictUpdate(_attendeeToCompanion(attendee));

      // A household owner or admin who isn't on the roster can add
      // themselves (#510), and the answer their lists show follows.
      await _writeOwnAnswer(attendee);

      await _db.batch((b) => _stampGeneration(b, [eventId]));
      return true;
    });
  }

  @override
  Future<bool> removeCachedAttendee({
    required String eventId,
    required String attendeeId,
  }) async {
    checkNotDisposed();
    return _db.transaction(() async {
      if (!await _isCachedAndServerOwned(eventId)) return false;

      final removed =
          await (_db.delete(_db.eventAttendeesTable)..where(
                (t) => t.id.equals(attendeeId) & t.eventId.equals(eventId),
              ))
              .go();
      if (removed == 0) return false;

      await _db.batch((b) => _stampGeneration(b, [eventId]));
      return true;
    });
  }

  @override
  Future<bool> cacheEventRow(Event event) async {
    checkNotDisposed();
    final id = event.id;
    return _db.transaction(() async {
      // Checked inside the transaction, which starts after the lock, so the
      // guards hold for the write.
      if (!await _isCachedAndServerOwned(id)) return false;

      // The companion leaves the two sync flags absent, so they stay as they
      // are, and it touches no child table.
      await (_db.update(
        _db.eventsTable,
      )..where((t) => t.id.equals(id))).write(_eventToCompanion(event));
      await _db.batch((b) => _stampGeneration(b, [id]));
      return true;
    });
  }

  @override
  Future<bool> removeCachedOccurrence({
    required String eventId,
    required String occurrenceId,
  }) async {
    checkNotDisposed();
    return _db.transaction(() async {
      if (!await _isCachedAndServerOwned(eventId)) return false;

      final removed =
          await (_db.delete(_db.eventOccurrencesTable)..where(
                (t) => t.id.equals(occurrenceId) & t.eventId.equals(eventId),
              ))
              .go();
      if (removed == 0) return false;

      await _db.batch((b) => _stampGeneration(b, [eventId]));
      return true;
    });
  }

  /// Whether [eventId] is cached, by any user's read, and the server's to
  /// write: neither `isDirty` nor `isLocalOnly`. Run inside the transaction
  /// that writes. One query, which on web is one message to the worker.
  Future<bool> _isCachedAndServerOwned(String eventId) async {
    final t = _db.eventsTable;
    final query = _db.selectOnly(t)
      ..addColumns([t.id])
      ..where(t.id.equals(eventId) & t.isDirty.not() & t.isLocalOnly.not());
    return await query.getSingleOrNull() != null;
  }

  /// Writes [attendee]'s answer onto the user's `attending` and `household`
  /// rows for its event, which the lists read first (#667, #503): only where
  /// [attendee] is the user's own row, and only where the rows exist.
  /// Answers how many rows it wrote. Run inside the transaction that writes
  /// the roster row.
  Future<int> _writeOwnAnswer(EventAttendee attendee) async {
    if (attendee.userId != _userId) return 0;
    return (_db.update(_db.eventAccessTable)..where(
          (t) =>
              t.eventId.equals(attendee.eventId) &
              t.userId.equals(_userId) &
              t.source.isIn(_answerSources),
        ))
        .write(_answerToCompanion(EventAttendance.fromAttendee(attendee)));
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

  /// The events this user has `household` access to whose household is
  /// [householdId], less any carrying local changes, each with its
  /// `generation`. There is no window: the household purge runs only when
  /// page 1 is the whole list (#503).
  Future<Map<String, int>> _purgeableHousehold(String householdId) async {
    final t = _db.eventsTable;
    final query = _db.selectOnly(t)
      ..addColumns([t.id, t.generation])
      ..where(
        t.id.isInQuery(_accessedEventIds(eventAccessSourceHousehold)) &
            t.householdId.equals(householdId) &
            t.isDirty.equals(false) &
            t.isLocalOnly.equals(false),
      );
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
  /// server sent this user, through the list, a detail read or a household's
  /// list. Rows cached only for other users are hidden, because the server
  /// never sent them to this one.
  Expression<bool> _readableEvent($EventsTableTable t) =>
      t.id.isInQuery(_accessedEventIds());

  /// Whether a roster read may return the `event_attendees` row [t]: one on
  /// a roster that names this user, or on one this user's own detail read was
  /// shown (#567).
  ///
  /// The rows are shared by every user signed in to this server on this
  /// device, and they hold other people's names and notes. The server shows
  /// a roster to the event's attendees, to its household's members and to
  /// staff, and an empty one to anyone else who may read the event
  /// (backend#560). So the gate answers from what the server sent this user,
  /// not from a copy of its role table: the user's row on the roster, or the
  /// `roster_shown` flag on their `read` row, which their detail read sets
  /// when it carried a roster and clears when it carried none. Everyone else
  /// reads it empty, as the server's empty roster reads. The flag follows a
  /// role change the next time the detail is read.
  Expression<bool> _readableAttendee($EventAttendeesTableTable t) {
    final me = _db.alias(_db.eventAttendeesTable, 'me');
    final shown = _db.alias(_db.eventAccessTable, 'shown');
    return t.eventId.isInQuery(
          _db.selectOnly(me)
            ..addColumns([me.eventId])
            ..where(me.userId.equals(_userId)),
        ) |
        t.eventId.isInQuery(
          _db.selectOnly(shown)
            ..addColumns([shown.eventId])
            ..where(
              shown.userId.equals(_userId) &
                  shown.source.equals(eventAccessSourceRead) &
                  shown.rosterShown,
            ),
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

    // The snapshot's three states: the roster for a user it names or one
    // whose own detail read was shown it (#567), empty for anyone else, and
    // null where no read has cached one.
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
  ///
  /// Each read takes in [id]'s move too, for [reconciledEventId] (#499). It
  /// is no part of the emission, so `distinct` drops a read as before.
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
  /// The row is the snapshot's own: a roster is read by a user it names or
  /// one it was shown to (#567), and the user's own row is on it only where
  /// they attend, so it is found there when it is, and one state of the cache
  /// gives both.
  Future<EventDetail?> _readDetail(String id) async {
    final snapshot = await _db.transaction(() async {
      final snapshot = await _readSnapshot(id);
      await _readMove(id);
      return snapshot;
    });
    if (snapshot == null) return null;
    return EventDetail(
      snapshot: snapshot,
      attendance: snapshot.attendees
          ?.where((attendee) => attendee.userId == _userId)
          .firstOrNull,
    );
  }

  /// Refreshes [_moves] with the move of the event [localId], if it has
  /// one, after the detail read of an emission for it and in its transaction
  /// (#499).
  ///
  /// A subscriber that asks [reconciledEventId] for the event it watches on
  /// an emission then finds its move if the detail reflects one, whichever
  /// repository or tab made it: a move commits with the deletion of its
  /// local event, is never removed, and this read sees the cache as the
  /// detail read saw it. Read before the detail, outside its transaction, a
  /// reconcile committing between the two would deliver the local event gone
  /// with no move known, and the detail would show it not found.
  ///
  /// The one row, by its key, not the table, which gains a row for every
  /// event created on this device and is read on every emission of every
  /// open detail. A server id never moves again, so no other row is needed.
  Future<void> _readMove(String localId) async {
    final move = await (_db.select(
      _db.eventMovesTable,
    )..where((t) => t.localId.equals(localId))).getSingleOrNull();
    if (move != null) _moves[move.localId] = move.serverId;
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

  /// One query joining each attending event to its occurrences, this user's
  /// `attending` and `household` rows and their own attendee row, so Drift
  /// re-runs it when any of them changes (#497), as `watchCollectionListItems`
  /// does for the collection.
  ///
  /// The attendance is the answer the `attending` row keeps, else the one the
  /// `household` row keeps (#503), else the user's row on the cached roster
  /// (#667). [_writeBatch] writes an answer onto both access rows wherever
  /// both exist, so they agree, and keeps the roster in step where it can.
  /// Where the roster still differs, as when the list answered for an
  /// attendee id the roster doesn't hold, the list is the newer news.
  ///
  /// Left outer joins: an event can have no occurrences, most have no cached
  /// roster, and most have only one of the two access rows. None of the other
  /// joins can repeat the occurrences. Each access join matches the row's
  /// whole key, user, event and source, so it joins one row, and never another
  /// user's or a `read` row.
  /// The attendee join matches on this user, so another user's row on a shared
  /// roster never joins. The server holds one row per user per event, a roster
  /// is replaced wholesale, and a list row only updates the user's row in
  /// place, so it joins at most one row.
  @override
  Stream<List<EventListItem>> watchAttendingEventListItems() => _watchListItems(
    (events) =>
        events.id.isInQuery(_accessedEventIds(eventAccessSourceAttending)),
  );

  @override
  Stream<List<EventListItem>> watchHouseholdEventListItems(
    String householdId,
  ) => _watchListItems(
    (events) =>
        events.id.isInQuery(_accessedEventIds(eventAccessSourceHousehold)) &
        events.householdId.equals(householdId),
  );

  /// The list-item query for the events [where] selects, which the attending
  /// and household lists share.
  Stream<List<EventListItem>> _watchListItems(
    Expression<bool> Function($EventsTableTable events) where,
  ) => untilDisposed(() {
    final events = _db.eventsTable;
    final occurrences = _db.eventOccurrencesTable;
    final attending = _db.alias(_db.eventAccessTable, 'own_access');
    final household = _db.alias(_db.eventAccessTable, 'own_household');
    final mine = _db.alias(_db.eventAttendeesTable, 'own_attendance');

    final query =
        _db.select(events).join([
            leftOuterJoin(
              occurrences,
              occurrences.eventId.equalsExp(events.id),
            ),
            leftOuterJoin(
              attending,
              attending.userId.equals(_userId) &
                  attending.eventId.equalsExp(events.id) &
                  attending.source.equals(eventAccessSourceAttending),
            ),
            leftOuterJoin(
              household,
              household.userId.equals(_userId) &
                  household.eventId.equalsExp(events.id) &
                  household.source.equals(eventAccessSourceHousehold),
            ),
            leftOuterJoin(
              mine,
              mine.eventId.equalsExp(events.id) & mine.userId.equals(_userId),
            ),
          ])
          ..where(where(events))
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
            attendance: _listAttendance(
              eventRows.first.readTableOrNull(attending),
              eventRows.first.readTableOrNull(household),
              eventRows.first.readTableOrNull(mine),
            ),
          ),
      ];
    });
  });

  /// A list item's attendance (#667): the answer the user's [attending] row
  /// keeps, else the one their [household] row keeps (#503), else their [own]
  /// row on the cached roster, else null.
  EventAttendance? _listAttendance(
    EventAccessTableData? attending,
    EventAccessTableData? household,
    EventAttendeesTableData? own,
  ) =>
      _mapAnswer(attending) ??
      _mapAnswer(household) ??
      (own == null ? null : EventAttendance.fromAttendee(_mapAttendee(own)));

  // ── Mappers ────────────────────────────────────────────────────────────

  /// The answer the `attending` or `household` access [row] keeps, or null
  /// where there is no row or it keeps none (#667, #503). Its names read back
  /// as a roster row's do, so one this client can't read is `unknown`.
  static EventAttendance? _mapAnswer(EventAccessTableData? row) {
    if (row == null) return null;
    final (attendeeId, status) = (row.attendeeId, row.attendanceStatus);
    if (attendeeId == null || status == null) return null;
    final role = row.attendanceRole;
    return EventAttendance(
      attendeeId: attendeeId,
      status: EventParticipationStatus.fromWire(status),
      role: role == null ? null : EventRole.fromWire(role),
      rsvpDate: row.rsvpDate,
    );
  }

  /// The four columns of an `attending` or `household` access row that keep
  /// [a], the user's own answer, or clear it where [a] is null (#667, #503).
  /// Stored as a roster row stores them.
  static EventAccessTableCompanion _answerToCompanion(EventAttendance? a) =>
      EventAccessTableCompanion(
        attendeeId: Value(a?.attendeeId),
        attendanceStatus: Value(a == null ? null : _statusName(a.status)),
        attendanceRole: Value(_roleName(a?.role)),
        rsvpDate: Value(a?.rsvpDate),
      );

  /// What a status column stores for [status].
  static String _statusName(EventParticipationStatus status) => storedEnumName(
    status,
    EventParticipationStatus.unknown,
    (v) => v.toWire(),
  );

  /// What a role column stores for [role]: null for no role.
  static String? _roleName(EventRole? role) => role == null
      ? null
      : storedEnumName(role, EventRole.unknown, (v) => v.toWire());

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
    cancelReason: row.cancelReason,
    cancelledAt: row.cancelledAt,
    isDirty: row.isDirty,
    isLocalOnly: row.isLocalOnly,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  /// The server's copy of [e]: every column but the two sync flags. Left
  /// absent, an insert takes their defaults, since a server copy carries no
  /// local sync state (#298's rule for households). The model's own flags are
  /// never written, and the upsert never reaches a row whose flags are set,
  /// because [_writeSnapshots] leaves that event alone.
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
        type: storedEnumName(e.type, EventType.unknown, (v) => v.toWire()),
        reach: storedEnumName(e.reach, Reach.unknown, (v) => v.toWire()),
        status: storedEnumName(
          e.status,
          EventStatus.unknown,
          (v) => v.toWire(),
        ),
        schedulingMode: storedEnumName(
          e.schedulingMode,
          EventSchedulingMode.unknown,
          (v) => v.toWire(),
        ),
        cancelReason: Value(e.cancelReason),
        cancelledAt: Value(e.cancelledAt),
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
        cancelReason: row.cancelReason,
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
        status: storedEnumName(
          o.status,
          OccurrenceStatus.unknown,
          (v) => v.toWire(),
        ),
        sortOrder: o.sortOrder,
        confirmedAt: Value(o.confirmedAt),
        declinedAt: Value(o.declinedAt),
        cancelledAt: Value(o.cancelledAt),
        cancelReason: Value(o.cancelReason),
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

  EventAttendeesTableCompanion _attendeeToCompanion(EventAttendee a) =>
      EventAttendeesTableCompanion.insert(
        id: a.id,
        eventId: a.eventId,
        userId: Value(a.userId),
        guestName: Value(a.guestName),
        username: Value(a.username),
        displayName: Value(a.displayName),
        avatarUrl: Value(a.avatarUrl),
        notes: Value(a.notes),
        status: _statusName(a.status),
        roleName: Value(_roleName(a.role)),
        rsvpDate: Value(a.rsvpDate),
        createdAt: a.createdAt,
        updatedAt: a.updatedAt,
      );

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
        gameAdditionMode: storedEnumName(
          p.gameAdditionMode,
          GameAdditionMode.unknown,
          (v) => v.toWire(),
        ),
        restrictToAttendeePool: p.restrictToAttendeePool,
        fillerMaxPlayTime: Value(p.fillerMaxPlayTime),
        voteThresholdType: storedEnumName(
          p.voteThresholdType,
          VoteThresholdType.unknown,
          (v) => v.toWire(),
        ),
        voteThresholdValue: Value(p.voteThresholdValue),
        voteQuorumType: storedEnumName(
          p.voteQuorumType,
          VoteQuorumType.unknown,
          (v) => v.toWire(),
        ),
        voteQuorumValue: Value(p.voteQuorumValue),
        voteEligibility: storedEnumName(
          p.voteEligibility,
          VoteEligibility.unknown,
          (v) => v.toWire(),
        ),
        interestedWeight: storedEnumName(
          p.interestedWeight,
          InterestedWeight.unknown,
          (v) => v.toWire(),
        ),
        votingWindowHours: Value(p.votingWindowHours),
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
      );
}
