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
/// read as one user (#496).
///
/// Events are read-only on the device for now. The repository caches what
/// the two event reads return, the list (`GET /events`) and the detail
/// (`GET /events/:id`), and serves reads from that. Creating an event is
/// #499, and answering an invitation or voting is #527.
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
/// [watchAttendingEvents] streams close.
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
/// the server through `read:public_content`. #498 and #503 widen the rule as
/// they start caching those reads.
///
/// The occurrences and the policy need no such rule: the server checks their
/// reads apart from the event's, but grants them wherever it grants the
/// event's, so anyone who may read an event may read its dates and its rules.
///
/// ## What each read may change
///
/// [cacheEvent] and [cacheEvents] trust each part of a snapshot as far as the
/// read that carried it can vouch for:
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
  /// and a cached row keeps the flags a local writer set. Nothing sets either
  /// yet, and #499 decides whether a server write may refresh an event the
  /// sync queue owns.
  Future<void> cacheEvent(
    EventSnapshot snapshot, {
    required EventAccessSource source,
  });

  /// Writes a page of [snapshots] for the current user, each as [cacheEvent]
  /// writes one, all in one transaction.
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
}
