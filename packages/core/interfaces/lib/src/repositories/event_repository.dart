import 'package:models/domain.dart';

/// Why the current user may read a cached event (#496).
enum EventAccessSource {
  /// It is on their list: the `GET /events` hydrate cached it because they
  /// hold an attendee row on it that no host has removed. The row counts
  /// whatever its RSVP, so an invitation they haven't answered and an event
  /// they declined are here too. It doesn't mean they said yes: their answer
  /// is their row on the roster. The only access
  /// [EventRepository.purgeAttendanceAbsentFrom] removes.
  attending,

  /// They read it by id, through `GET /events/:id`, whether or not they
  /// attend it. No purge removes it.
  read,
}

/// Read cache of the events the server sent each user, for a single server,
/// read as one user (#496), and the local half of creating one (#499).
///
/// The repository caches what the two event reads return, the list
/// (`GET /events`) and the detail (`GET /events/:id`), and serves reads from
/// that. [create] is its one local write: it writes a local-only event and
/// queues its create, and the sync queue owns that event until
/// [reconcileCreatedEvent] replaces it with the server's. Answering an
/// invitation or voting is #527, and editing an event #500.
///
/// ## Per user
///
/// An instance belongs to one user's session and is resolved from that
/// session's scope. The cache stores each event once per server, whichever
/// users signed in to it on this device it was cached for, and records each
/// user it was sent to and why, as an [EventAccessSource]. Every read returns
/// only events recorded for this instance's user. An event the server sent
/// only to another user reads as not cached, whatever its reach, because
/// what decides it is what the server sent each user.
///
/// After the session ends the `Future` methods throw [StateError], and
/// [watchAttendingEvents] streams close. [reconciledEventId] still answers.
///
/// ## The roster, only to a user on it
///
/// The roster is stored once per event the same way, and it holds other
/// people's names, guests' names and their notes. The server shows an event's
/// attendee list to its attendees, since every event role may read it, and
/// to members of the event's household. Anyone else who may read the event,
/// such as a friend, a household guest or a public reader, is served an empty
/// list (backend#560).
///
/// [getEvent] serves a cached roster only to a user it names, and an empty
/// list to everyone else, meaning what the server's empty list means: this
/// user may not read it. Where no read has cached a roster, it answers null
/// instead: not known. The rule deliberately consults only the roster for
/// now, though `household_members` is cached in the same database, so a
/// household member who doesn't attend reads an empty roster where the
/// server would show them the list. So do staff, who read every roster on
/// the server through `read:public_content`. #567 widens the rule.
///
/// The occurrences and the policy need no such rule: the server checks their
/// reads apart from the event's, but grants them wherever it grants the
/// event's, so anyone who may read an event may read its dates and its rules.
///
/// ## What each read may change
///
/// [cacheEvent] and [cacheEvents] trust each part of a snapshot as far as the
/// read that carried it can vouch for. An event that is `isDirty` or
/// `isLocalOnly` is the exception: it belongs to the sync queue until the
/// server acknowledges it, so a read writes nothing of it, not the event, its
/// occurrences, its roster, its policy, its generation or its access. The
/// events beside it on the same page are written as usual, and a read after
/// the flags clear writes it again. For the rest:
///
/// - **The event** is written whole on every read. Its `updatedAt` is not
///   bumped by attendee, occurrence or vote writes, so it can't be used to
///   skip one.
/// - **Occurrences** are replaced wholesale on every read, an empty list
///   included. Both reads serve all of an event's occurrences, and the server
///   hard-deletes one, so a merge would keep dates that no longer exist.
/// - **The roster** is replaced only by a snapshot carrying at least one
///   attendee. The list carries none, and an empty roster is one the caller
///   may not read, so neither says anyone else left. An empty one does say
///   the caller isn't on it, though, since an attendee always sees
///   themselves, so it removes the caller's own row. Kept, it would still
///   show them the roster and their old role. Where theirs was the only row
///   cached, no roster is left, and [getEvent] answers null.
/// - **The policy** is replaced only by a snapshot carrying one. A read serves
///   none to a caller its own check refuses, and the server has no policy
///   delete, so a missing one is never news.
///
/// ## Removals made elsewhere
///
/// An event the user no longer attends, because they left it, a host removed
/// them or it was deleted, leaves their list on the next hydrate, by
/// [purgeAttendanceAbsentFrom]. The list is ordered by creation and can run
/// to many pages, and only its first page is one consistent read, so a pass
/// purges only within the range that page spans: an event created before it
/// stays cached until the list fits on one page.
abstract class EventRepository {
  /// Writes one read's [snapshot] for the current user, in one transaction:
  ///
  /// - upserts the event, and its policy when the snapshot carries one;
  /// - replaces its occurrences wholesale;
  /// - replaces its roster only when `snapshot.attendees` is non-empty, and
  ///   removes the current user's own row from it when it is empty;
  /// - records [source] access for the current user, beside any access they
  ///   already have.
  ///
  /// For one read, such as the detail read #498 makes. The hydrate writes a
  /// page at a time, through [cacheEvents].
  ///
  /// The cache holds one copy of each event per server, so any user's write
  /// refreshes the copy every user with access to it reads.
  ///
  /// The write leaves the event's sync state alone: a new row starts with
  /// `isDirty` and `isLocalOnly` false, whatever the snapshot's event says,
  /// and a cached row keeps the flags a local writer set.
  ///
  /// An event that is `isDirty` or `isLocalOnly` is left alone entirely, as
  /// #298 has it for households: it belongs to the sync queue until the
  /// server acknowledges it, and a server copy written over it would undo
  /// what the queue is about to send. Nothing of it is written, whatever the
  /// snapshot says. A read after the flags clear writes it as any other.
  Future<void> cacheEvent(
    EventSnapshot snapshot, {
    required EventAccessSource source,
  });

  /// Writes a page of [snapshots] for the current user, each as [cacheEvent]
  /// writes one, all in one transaction. An event that is `isDirty` or
  /// `isLocalOnly` is skipped as there, and the others are written.
  ///
  /// The hydrate writes up to a hundred events a page. A transaction per
  /// event had a live [watchAttendingEvents] rebuild its list once per event
  /// on every pass, and show the page half written in between: a 300-event
  /// list gave a subscriber 300 lists per pass. In one transaction it emits
  /// once a page.
  Future<void> cacheEvents(
    List<EventSnapshot> snapshots, {
    required EventAccessSource source,
  });

  /// The events [purgeAttendanceAbsentFrom] could remove the current user's
  /// attendance of right now, as event id to a value naming the last write
  /// of the cached event, which no later write repeats: every event they
  /// have `attending` access to, less any that are `isDirty` or
  /// `isLocalOnly`.
  ///
  /// Read it **before** requesting the first page, and pass it to the purge.
  /// An event written after this read, by any read, is one a newer read of
  /// the server may have sent than the snapshot the purge judges, and the
  /// purge leaves it alone. That covers an event first cached since, and one
  /// already cached that the user left and was invited back to, which
  /// another tab's pass may cache while this one's page is in flight,
  /// whether or not a purge deleted it in between. This reads the database,
  /// so a write from any repository over it counts, another browser tab's
  /// included.
  Future<Map<String, int>> purgeableAttendance();

  /// Removes the current user's `attending` access to each event in
  /// [purgeable] that [snapshotIds] doesn't name, in one transaction, and
  /// returns the ids of the events it removed it from.
  ///
  /// [snapshotIds] must be the events on **one consistent read** of the
  /// user's list: its first page.
  ///
  /// - [newerThan] null: that page was the whole list (`hasMore: false`), so
  ///   an attending event it doesn't name is gone.
  /// - [newerThan] set: the list goes on past that page, which vouches only
  ///   for the range it spans. Only events created strictly after
  ///   [newerThan], the page's last `createdAt`, are considered. One created
  ///   at that same instant is kept: the server orders a tie by id, in a
  ///   collation this device can't reproduce, so it may be on the next page.
  ///
  /// [purgeable] is a [purgeableAttendance] read taken before that page was
  /// requested. Nothing outside it is removed, and neither is an event that
  /// has become `isDirty` or `isLocalOnly` since, nor one written since.
  ///
  /// Only this user's `attending` access is removed, because the list speaks
  /// for their attendance and nothing else: their `read` access stays, and so
  /// does every other user's. Their own row on each such event's cached
  /// roster goes with it, in the same transaction. The list holds every event
  /// they have an attendee row in that no host has removed, so one it leaves
  /// out is one they no longer attend. Kept, wherever their `read` access
  /// keeps the event readable, their row would still give
  /// [getCurrentUserAttendance] their old role and RSVP, and let [getEvent]
  /// show them the roster, though the server now serves them none. Every
  /// other row on the roster stays.
  ///
  /// An event left with no access row at all, from any user, is deleted with
  /// its occurrences, roster and policy, since no read can reach it.
  Future<Set<String>> purgeAttendanceAbsentFrom(
    Set<String> snapshotIds, {
    required Map<String, int> purgeable,
    DateTime? newerThan,
  });

  /// The cached event [id] as one snapshot, or null when it isn't cached or
  /// the current user has no access to it.
  ///
  /// The occurrences come in the server's order, `sortOrder` then id, and the
  /// roster in its order, `createdAt` then id. The policy is null until a
  /// read carries one.
  ///
  /// `attendees` keeps "not asked" apart from "may not read", as
  /// [EventSnapshot.attendees] does (see "The roster, only to a user on it"
  /// above):
  ///
  /// - null when no roster is cached for the event, as for one cached only
  ///   from the list: not known, so read the detail;
  /// - empty when a roster is cached that doesn't name the current user,
  ///   meaning what the server's empty roster means: they may not read it;
  /// - the cached roster when it names them.
  Future<EventSnapshot?> getEvent(String id);

  /// The current user's own row on the cached roster of [eventId], or null
  /// when no cached roster names them or they have no access to the event.
  ///
  /// Only a detail read carries a roster until backend#867 puts the caller's
  /// own attendance on every list row, so an event cached only from the list
  /// answers null.
  Future<EventAttendee?> getCurrentUserAttendance(String eventId);

  /// Watches the cached event [id] as the detail screen shows it (#498): what
  /// [getEvent] answers, paired with what [getCurrentUserAttendance] answers.
  ///
  /// Emits on listen, null where [getEvent] would answer null, and again
  /// after any write to the event, its occurrences, its roster, its policy or
  /// anyone's access to it: each [cacheEvent], each page [cacheEvents]
  /// writes, and each purge or [forgetEvent] that removed something. So a
  /// subscriber sees the event leave the cache, as null, when the user's
  /// access to it goes.
  ///
  /// The two halves of an emission are read in one transaction, so a write
  /// landing between them can't pair one state of the roster with another's
  /// attendance. The attendance is this user's own row alone, as everywhere
  /// else: another user's row on the same roster is never this user's.
  ///
  /// A write that changes nothing here, such as another user's cache of an
  /// event of theirs, may still re-read it, and consecutive equal emissions
  /// are dropped. After disposal the stream is already closed.
  Stream<EventDetail?> watchEvent(String id);

  /// A value naming the last write of the cached event [id], as
  /// [purgeableAttendance] names one, which no later write repeats, or null
  /// when it isn't cached or the current user has no access to it.
  ///
  /// Read it **before** sending the detail read, and pass it to
  /// [forgetEvent] if that read answers 404.
  Future<int?> lastWrite(String id);

  /// Removes the current user's access to the cached event [id], for an
  /// event the server no longer serves them (a 404 on its detail read), and
  /// returns whether it did.
  ///
  /// [lastWrite] is a [EventRepository.lastWrite] read taken before that
  /// read was sent. An event written since, by any read, is one a newer
  /// answer from the server may have sent than the 404, and is left alone:
  /// a read that outlives its screen can answer after the event was opened
  /// again and cached, or after a hydrate cached it once the user was
  /// invited back.
  ///
  /// In one transaction it removes their access rows of both sources, then
  /// their own row on the event's roster, and then deletes the event with its
  /// occurrences, roster and policy if no user has an access row left, as
  /// [purgeAttendanceAbsentFrom] does. Another user's access and their row
  /// on the roster stay, so the event keeps reading for them. The roster row
  /// goes for the reason [purgeAttendanceAbsentFrom] gives: kept, it would
  /// still answer with the user's old role and RSVP.
  ///
  /// Returns true when it removed access. Returns false, and changes
  /// nothing, when the user had no access to the event, when it has been
  /// written since [lastWrite], or when the event is `isDirty` or
  /// `isLocalOnly`: the sync queue owns those until the server acknowledges
  /// them, and an event created offline is one the server has never heard
  /// of, so its 404 says nothing about it (#298's rule for households).
  Future<bool> forgetEvent(String id, {required int lastWrite});

  /// Watches the events the current user has `attending` access to, in the
  /// list's order: newest created first, the higher id first on a tie. An
  /// event they only read is left out, and one they declined or haven't
  /// answered is in: see [EventAccessSource.attending].
  ///
  /// Emits a fresh list when a write changes this user's attending events:
  /// each [cacheEvent], each page [cacheEvents] writes, once for the whole
  /// page, and each purge that removed something. A purge that removes
  /// nothing writes nothing and emits nothing. A write that leaves the list
  /// as it was, such as another user's, may still emit it unchanged.
  Stream<List<Event>> watchAttendingEvents();

  /// Watches the same events as [watchAttendingEvents], in the same order,
  /// each with its occurrences and the current user's own attendee row
  /// (#497).
  ///
  /// The occurrences come in the server's order, `sortOrder` then id, and an
  /// event with none has an empty list. The attendee row is the one
  /// [getCurrentUserAttendance] answers: null where no cached roster names
  /// this user, which for an event cached only from the list is every one
  /// until backend#867. Another user's row on the same roster is never this
  /// user's.
  ///
  /// Re-emits when an event, its occurrences or this user's attendee row
  /// changes, and on each write [watchAttendingEvents] emits for. As there,
  /// a write that changes nothing here may still emit the list unchanged.
  Stream<List<EventListItem>> watchAttendingEventListItems();

  // ── The queued create (#499) ───────────────────────────────────────────

  /// Creates the event [draft] describes, with the current user as its host.
  ///
  /// Writes the event locally with `isLocalOnly` and `isDirty` set, and
  /// enqueues a [CreateEventOperation] carrying [draft], in one transaction:
  /// if the enqueue fails, nothing is written. The event is listed and read
  /// at once, for the current user alone.
  ///
  /// The local event is what the server makes of [draft]:
  ///
  /// - its title trimmed, and where [draft] leaves them null, the type and
  ///   reach the server defaults to, a casual gathering for friends;
  /// - `planning` for a poll, with each date `proposed`, and otherwise
  ///   `scheduled`, with each date `confirmed` now;
  /// - each occurrence's `sortOrder` its position in [draft];
  /// - a roster of the current user alone, as host and attending.
  ///
  /// It has no policy and no invitees. The reconcile brings both.
  ///
  /// This does not contact the server. The sync queue sends the op and calls
  /// [reconcileCreatedEvent] with the answer. Until then the event belongs to
  /// the queue: no read writes over it, and neither a purge nor
  /// [forgetEvent] removes it.
  ///
  /// Returns the local event, the `syncQueueId` of its op, which the caller
  /// passes to [reconcileCreatedEvent] so the op closes with it, and the
  /// `operation` as it was queued. A caller that sends it inline sends that
  /// `operation`, so the send carries every field a later drain's would.
  ///
  /// Throws [ArgumentError], before any write, for a draft the server is
  /// sure to refuse, since a queued create it refuses is parked on its first
  /// attempt: a blank title, more than one occurrence on a Fixed event, what
  /// [EventDraft.checkSendable] refuses, and a household created on this
  /// device that the server has yet to confirm, whose id it has never heard
  /// of. A household confirmed since, under the server's id, is sent and
  /// cached under that id. The url is the one field left to the caller to
  /// check, as [EventDraft.checkSendable] explains.
  Future<({Event event, String syncQueueId, CreateEventOperation operation})>
  create(EventDraft draft);

  /// Replaces the local event [create] wrote under [localId] with [server],
  /// the event the server made of it, in one transaction.
  ///
  /// The local event is removed with its occurrences, roster and access,
  /// while it is still `isLocalOnly`. Unless [deleted], [server] is then
  /// cached by the rules [cacheEvent] writes a read by: as attended, or as
  /// [EventAccessSource.read] where its roster leaves the current user off.
  /// Where its id differs from [localId] the move is recorded for
  /// [reconciledEventId]. When [completedSyncQueueId] is given, that queue
  /// entry is completed in the same transaction. If any step throws, all of
  /// it rolls back.
  ///
  /// So a copy of [server] a hydrate cached first is written over, and the
  /// cache holds one event, under the server's id. A repeat of the create
  /// answers with the event as its creator may read it now, so one who has
  /// left it since is not listed as attending it, even where a hydrate
  /// cached it as attended first, and one who has lost read
  /// on it gets an empty roster and no policy, which mean what they mean to
  /// [cacheEvent]. The create's answer embeds each attendee's role and not
  /// their user, so it names no one: an attendee keeps the name a cached
  /// roster already gave them, and the rest come with the next detail read.
  ///
  /// [deleted] is for a repeat of a create whose event was deleted since:
  /// the local event goes, and so does a copy a hydrate cached under
  /// [server]'s id, for every user, since the server deleted it for
  /// everyone. Nothing is cached in its place, and no move is recorded, so
  /// a screen holding [localId] finds the event gone.
  Future<void> reconcileCreatedEvent(
    EventSnapshot server, {
    required String localId,
    required bool deleted,
    String? completedSyncQueueId,
  });

  /// The id of the event [reconcileCreatedEvent] replaced [localId] with, or
  /// null if it has not: before the reconcile, when the server kept the
  /// local id, when the event was deleted before the create was answered,
  /// and when a reconcile rolled back.
  ///
  /// For a screen that holds an event by its local id when the id changes
  /// under it: one open during the reconcile, or one opened on the local id
  /// afterwards. The local event is gone by then, so the local id reads as
  /// an event that is not cached.
  ///
  /// The move is stored with the reconcile, so it is found whichever
  /// repository made it, another tab's over the same database included, and
  /// after a reload. This answers from the moves this repository last
  /// recorded or read: its own reconciles, and the watched event's move,
  /// which it reads before delivering each [watchEvent] emission. A
  /// subscriber that checks this for the event it watches on every emission
  /// therefore sees a move on the emission that drops the local event. Asked
  /// before [watchEvent] has emitted for [localId], it may answer null for a
  /// move another repository made.
  ///
  /// Never throws, including after disposal.
  String? reconciledEventId(String localId);

  /// Discards the queued event create [syncQueueId] names, and the local
  /// event [create] wrote for it.
  ///
  /// Only for a create that is stuck: the server refused it, or its retries
  /// ran out. The event is deleted with its occurrences, roster and access,
  /// and the queue entry with them through
  /// `SyncQueueRepository.discardStuck`, in one transaction; a create that
  /// isn't stuck by then, such as one another tab retried, changes nothing.
  /// Only an event still [Event.isLocalOnly] is deleted. If the server did
  /// make it, a lost answer being how the retries ran out, the next hydrate
  /// brings it back.
  ///
  /// A completed or unknown entry changes nothing. A payload that won't
  /// decode is deleted, with the local event it names where it is an event
  /// create ([CreateEventOperation.localIdOf]), as one a newer build queued
  /// may be. Returns whether the entry
  /// was deleted. Throws [ArgumentError] for a collection or household op,
  /// before any write.
  Future<bool> discardQueuedOp(String syncQueueId);
}
