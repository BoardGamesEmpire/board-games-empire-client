import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What one [EventHydrator.hydrate] pass achieved.
///
/// As with households (#268), what matters is how much of the list the
/// server's answer vouched for, because only that licenses a purge. After any
/// outcome but [failed], every page the server sent was cached.
enum EventHydrateOutcome {
  /// Page 1 was the whole list: one consistent read of every event the server
  /// lists for this user, so absence from it is meaningful. Every attending
  /// event it didn't name was purged.
  complete,

  /// Every page was cached, and attending events within page 1's range were
  /// purged. The list ran past page 1, which vouches only for the events
  /// created after its last row: those it didn't name were purged, and older
  /// ones were kept.
  windowed,

  /// Every page was cached, and nothing was purged: page 1 could not vouch
  /// for the events it left out. Either it was the only page and sent fewer
  /// events than it counts, or more pages followed and it was short, numbered
  /// as another page, or counted in a way that disagrees with it.
  drained,

  /// The pass ended early on a failure. It keeps every page it wrote, and any
  /// purge page 1 already made.
  failed,
}

/// Pulls the events the signed-in user attends from `GET /events` into the
/// per-user cache, and removes the attendance the server no longer lists
/// (#496).
///
/// That cache is the one copy every event screen is to read. Without this a
/// reinstall or a second device shows no events while the server holds the
/// user's list, and an event the user left, was removed from, or that was
/// deleted stays on it.
///
/// ## It must never throw
///
/// It runs from user-session activation, where a throw converges to a
/// sign-out, for the reasons `HouseholdHydrator` records: an escaping error
/// would turn *server unreachable* into *forced sign-out*. So [hydrate]
/// reports failure in its return value and catches by [Object]: an
/// [EventRemoteException], the [ArgumentError] the data source raises for
/// paging it rejects locally, and the [StateError] the repository throws once
/// the session has ended mid-drain. A [confirmSession] that throws is caught
/// too, though `SessionIdentityGuard.confirm`, which backs it, never does.
///
/// ## The drain
///
/// Request [limit] rows and follow [PaginationMeta.hasMore], never a short
/// page, which is not a terminator against a filtered query. Like the
/// household's, this is a deliberate full drain rather than scroll paging:
/// the screens read the cache.
///
/// Every page is fetched although only page 1 licenses a purge. The list is
/// ordered by creation, not by date, so an old event with an upcoming date
/// can sit on page 3, and a screen that sorts by date needs it cached.
///
/// ## What a pass removes (#268)
///
/// Only the current user's `attending` access, through
/// [EventRepository.purgeAttendanceAbsentFrom], and with it their own row on
/// that event's cached roster: their `read` access stays, and so does every
/// other user's, roster rows included. An event no user can read any more is
/// deleted from the cache.
///
/// **A list that fits on page 1.** The server's contract is that a first page
/// with `hasMore: false` is one consistent read of the whole list, so an
/// attending event it doesn't name is gone, and the pass purges every one
/// ([EventHydrateOutcome.complete]). Such a page is held to the household's
/// checks first. One whose envelope contradicts itself fails the pass
/// ([EventHydrateOutcome.failed]), and one that sends fewer events than it
/// counts ends [EventHydrateOutcome.drained]. Neither purges anything.
///
/// **A longer list.** A walk across pages is not one snapshot: an event that
/// leaves the list between two requests shifts the rest up and can carry
/// another past a page boundary unseen, so no later page licenses a purge.
/// Page 1 still does, within the range it spans. Its rows and count come from
/// one REPEATABLE READ snapshot, and its order, `createdAt desc, id desc`, is
/// total, so an attended event that sorts inside page 1's range and is
/// missing from it really is gone. So page 1 purges the attending events
/// created after its last row that it doesn't name
/// ([EventHydrateOutcome.windowed]), but only when it can vouch for that
/// range: full, numbered 1, and counting more events than it holds in as
/// many pages as that makes. One that says another page follows past its own
/// last page fails the pass ([EventHydrateOutcome.failed]). Any other that
/// can't vouch purges nothing, and the pass ends at best
/// [EventHydrateOutcome.drained]: one numbered as another page, one with no
/// rows, one whose counts disagree with it, and one short of its limit, which
/// is not the API's own answer, since the server fills page 1 from the same
/// read it counts in. The purge runs as soon as page 1 is cached, before
/// page 2 is requested, so a later failure leaves it done, and the pass still
/// reports [EventHydrateOutcome.failed].
///
/// An event created at the same instant as page 1's last row is kept. The
/// server breaks that tie by id, in a collation SQLite can't reproduce, so
/// this device can't tell which side of the boundary it fell on.
///
/// The accepted cost: an event created before page 1's range that the user
/// leaves stays cached, and listed as theirs, until their list fits on one
/// page, or until a detail read answers 404 for it. Acting on that 404 comes
/// with the screens, #497 and #498.
///
/// The purge is limited to the events [EventRepository.purgeableAttendance]
/// named **before page 1 was requested**, and to those not written since: an
/// event cached while the request was in flight, by another tab's pass say,
/// can be missing from the response and still be the user's. That holds for
/// one already cached too, when the user left it and was invited back while
/// the request was in flight.
class EventHydrator {
  EventHydrator({
    required EventRepository repository,
    required this._remote,
    this.limit = EventRemoteDataSource.maxPageSize,
    this.confirmSession,
    BgeLogger? logger,
  }) : _repo = repository,
       _logger = logger ?? BgeLogger('bge.events.hydrate');

  final EventRepository _repo;
  final EventRemoteDataSource _remote;
  final BgeLogger _logger;

  /// Rows per request. Defaults to the server's own page-size cap.
  final int limit;

  /// Whether the session is still the user this cache belongs to, asked
  /// after each page comes back and before it is written (#432). Null, as on
  /// native, is always yes.
  ///
  /// On web another tab can move the shared session cookie to another user
  /// while a drain is paging, and every page read after that holds the other
  /// user's events. The rows carry nothing that says whose list they are, so
  /// only the session can be asked.
  final Future<bool> Function()? confirmSession;

  /// Drains the user's event list into the cache, purges what page 1
  /// licenses, and reports how much of the list that purge could judge.
  ///
  /// Never throws — see the class doc.
  ///
  /// Not single-flight: a drain deletes as well as writes, so the caller,
  /// `HydratePass`, runs one at a time (#302).
  Future<EventHydrateOutcome> hydrate() async {
    final Map<String, int> purgeable;
    try {
      purgeable = await _repo.purgeableAttendance();
    } on Object catch (error, stackTrace) {
      // A disposed repository, in practice; every write after it would fail
      // the same way. See the class doc.
      _logger.warn(
        'Event hydrate could not read the cache before starting',
        error: error,
        stackTrace: stackTrace,
      );
      return EventHydrateOutcome.failed;
    }

    // Whether page 1's purge ran, which makes a drain that reaches the end
    // windowed rather than drained.
    var windowed = false;
    var page = 1;

    while (true) {
      final PaginatedResult<EventSnapshot> result;
      try {
        result = await _remote.fetchEvents(page: page, limit: limit);
      } on Object catch (error, stackTrace) {
        // `Object`, not `EventRemoteException`: the data source throws
        // ArgumentError for paging it rejects locally, outside its own
        // taxonomy. Nothing retries here: user-session activate is the retry
        // point, and the remote reads a list 404 as transient, so a server
        // without the events routes fails a pass rather than ending
        // hydration for the life of the process.
        _logger.warn(
          'Event hydrate stopped on a failed page',
          error: error,
          stackTrace: stackTrace,
          context: {'page': page, 'limit': limit},
        );
        return EventHydrateOutcome.failed;
      }

      if (!await _confirmed(page)) return EventHydrateOutcome.failed;

      try {
        // The whole page in one write, so a screen watching the list
        // rebuilds once for it rather than once per event.
        await _repo.cacheEvents(
          result.items,
          source: EventAccessSource.attending,
        );
      } on Object catch (error, stackTrace) {
        // Ordinarily worth rethrowing, since a disposed repository is a real
        // fault, but not out of here. See the class doc.
        _logger.warn(
          'Event hydrate stopped on a failed cache write',
          error: error,
          stackTrace: stackTrace,
          context: {'page': page, 'limit': limit},
        );
        return EventHydrateOutcome.failed;
      }

      if (!result.meta.hasMore) {
        if (page == 1) return _finishWholeList(result, purgeable);
        return windowed
            ? EventHydrateOutcome.windowed
            : EventHydrateOutcome.drained;
      }

      // `hasMore` past the last page the server itself counted is an
      // envelope that contradicts itself, and nothing else would stop the
      // drain until the server refused a page past its offset ceiling, a
      // thousand requests on at the default limit. Checked before page 1's
      // purge, so a page 1 like that purges nothing.
      if (page >= result.meta.totalPages) {
        _logger.warn(
          'Event list reports another page past its own last page; ending '
          'the drain. The cached set is NOT complete.',
          context: {
            'page': page,
            'totalPages': result.meta.totalPages,
            'total': result.meta.total,
            'limit': result.meta.limit,
          },
        );
        return EventHydrateOutcome.failed;
      }

      if (page == 1) {
        final newerThan = _windowFloor(result);
        if (newerThan != null) {
          if (!await _purge(result.items, purgeable, newerThan: newerThan)) {
            return EventHydrateOutcome.failed;
          }
          windowed = true;
        }
      }

      page++;
    }
  }

  /// Whether the page that just came back may be written: [confirmSession]
  /// said yes, or there is none to ask. A no is logged.
  Future<bool> _confirmed(int page) async {
    final confirm = confirmSession;
    if (confirm == null) return true;

    final bool confirmed;
    try {
      confirmed = await confirm();
    } on Object catch (error, stackTrace) {
      // The guard behind it never throws, but nothing may escape from here.
      _logger.warn(
        'Event hydrate stopped: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
        context: {'page': page},
      );
      return false;
    }
    if (!confirmed) {
      _logger.info(
        'Event hydrate stopped: a page came back once the session could no '
        'longer be confirmed as this user\'s',
        context: {'page': page},
      );
    }
    return confirmed;
  }

  /// Ends a pass whose page 1 says it is the whole list, purging against it
  /// when its envelope agrees with itself and it sent every event it counts.
  Future<EventHydrateOutcome> _finishWholeList(
    PaginatedResult<EventSnapshot> pageOne,
    Map<String, int> purgeable,
  ) async {
    final meta = pageOne.meta;
    final rows = pageOne.items.length;
    final counts = {
      'rows': rows,
      'page': meta.page,
      'totalPages': meta.totalPages,
      'total': meta.total,
      'limit': meta.limit,
    };
    // The purge deletes whatever page 1 leaves out, so `hasMore` alone does
    // not license it. A page 1 contradicts itself when it is numbered as
    // another page, counts other than one page, counts more events than one
    // page holds, or counts fewer events than it sent. The server derives
    // `totalPages` from `total` over `limit`, rounded up, so a single page
    // counts one, or none when it is empty.
    if (meta.page != 1 ||
        meta.totalPages != (meta.total == 0 ? 0 : 1) ||
        meta.total > meta.limit ||
        rows > meta.total) {
      _logger.warn(
        'Event list reports page 1 as its last but contradicts itself; '
        'purging nothing. The cached set is NOT complete.',
        context: counts,
      );
      return EventHydrateOutcome.failed;
    }
    // A page short of its count does not contradict itself, but it is not
    // the API's own answer: the server reads the rows and the count in one
    // REPEATABLE READ, under the same filter, and filters nothing after, so
    // its only page holds every event it counts. A shorter one came through
    // something else, a proxy or a truncated response, and a count it
    // doesn't back up proves nothing about the rows it left out. Every row
    // it sent is cached, so the pass did not fail, but it purges nothing.
    if (rows < meta.total) {
      _logger.warn(
        'Event list sent fewer events than it counts on its only page; '
        'caching them and purging nothing.',
        context: counts,
      );
      return EventHydrateOutcome.drained;
    }
    return await _purge(pageOne.items, purgeable)
        ? EventHydrateOutcome.complete
        : EventHydrateOutcome.failed;
  }

  /// The `createdAt` of page 1's last row, which bounds the range a list
  /// longer than page 1 vouches for, or null when page 1 can't vouch for it.
  ///
  /// Only a full page numbered 1 whose counts agree with it can. The server
  /// fills a first page that has more to follow: it reads the rows and the
  /// count in one REPEATABLE READ, under the same filter. So one short of its
  /// limit is not the API's own answer but a proxy's or a truncated one, and
  /// proves nothing about the rows within its range it left out. One whose
  /// counts disagree did not come from one read of the list it says it
  /// heads: the server counts `total` in the same read as the rows and
  /// derives `totalPages` from it, rounded up, so a first page with more to
  /// follow counts more events than it holds, in as many pages as that
  /// makes. A null is logged.
  DateTime? _windowFloor(PaginatedResult<EventSnapshot> pageOne) {
    final meta = pageOne.meta;
    final rows = pageOne.items;
    // Not empty, as well as full: an envelope counting a limit of zero would
    // make no rows a full page, with no last row to read. Past those two the
    // limit is positive, so the page count can be derived from it. Behind the
    // drain's guard that count already implies `total > limit`, but both are
    // checked so this stands without the guard.
    if (meta.page == 1 &&
        rows.isNotEmpty &&
        rows.length == meta.limit &&
        meta.total > meta.limit &&
        meta.totalPages == (meta.total + meta.limit - 1) ~/ meta.limit) {
      return rows.last.event.createdAt;
    }
    _logger.warn(
      'Event list sent a first page that cannot vouch for its range: short, '
      'numbered as another page, or counted in a way that disagrees with it. '
      'Caching every page and purging nothing.',
      context: {
        'rows': rows.length,
        'page': meta.page,
        'totalPages': meta.totalPages,
        'total': meta.total,
        'limit': meta.limit,
      },
    );
    return null;
  }

  /// Removes the current user's attendance of each event in [purgeable] that
  /// [pageOne] doesn't name, among those created after [newerThan] when it is
  /// set, and logs what it removed.
  ///
  /// Returns false when the purge failed, which it logs.
  Future<bool> _purge(
    List<EventSnapshot> pageOne,
    Map<String, int> purgeable, {
    DateTime? newerThan,
  }) async {
    try {
      final purged = await _repo.purgeAttendanceAbsentFrom(
        {for (final snapshot in pageOne) snapshot.event.id},
        purgeable: purgeable,
        newerThan: newerThan,
      );
      if (purged.isNotEmpty) {
        _logger.info(
          'Event hydrate removed the attendance of events the server no '
          'longer lists for this user',
          context: {
            'eventIds': purged.toList()..sort(),
            'windowed': newerThan != null,
          },
        );
      }
      return true;
    } on Object catch (error, stackTrace) {
      // A cache write like any other; see the drain's.
      _logger.warn(
        'Event hydrate could not purge against page 1',
        error: error,
        stackTrace: stackTrace,
        context: {'windowed': newerThan != null},
      );
      return false;
    }
  }
}
