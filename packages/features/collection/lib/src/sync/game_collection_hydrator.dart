import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What one [GameCollectionHydrator.hydrate] pass achieved.
///
/// Nothing purges against a collection hydrate, so the household's
/// completeness question (#268) does not arise here. What is left is whether
/// the pass read everything it meant to.
enum CollectionHydrateOutcome {
  /// Every page was read and written, and the catch-up pass too when one
  /// was needed.
  complete,

  /// The pass ended early on a failure. Whatever landed before it is kept.
  failed,
}

/// Pulls the user's collection from the server into the local cache when a
/// user session activates (#259, #44).
///
/// Without it the collection cache holds only what this device added, so a
/// reinstall or a second device shows an empty list while the server holds
/// the user's games.
///
/// ## Each page is written summaries first
///
/// A collection row has an enforced foreign key onto its platform game, and
/// that onto its game. Nothing else writes those from the network, so on a
/// fresh device the entry alone cannot be stored. Every page therefore
/// writes the platform game summaries its live rows embed first, through
/// [GameRepository.cachePlatformGameSummaries], and only then its entries.
/// A tombstone skips the summary: merging one only ever deletes.
///
/// Each of those is one write for the whole page, not one per row. A list
/// open during the hydrate then grows a page at a time, rather than
/// re-running its join after every row and showing each partial state.
///
/// The entry goes through [GameCollectionRepository.mergeFromServer], not
/// `reconcileFromServer`. This is server state nobody on this device asked
/// for, and a row the user changed offline must keep that change until the
/// sync queue sends it.
///
/// ## It must never throw
///
/// It runs from user-session activation, where a throw converges to a
/// sign-out, for the reasons `HouseholdHydrator` records. So [hydrate]
/// reports failure in its return value and catches by [Object]: a
/// [GameCollectionRemoteException], the [ArgumentError] the data source
/// raises for paging it rejects locally, and the [StateError] a repository
/// throws once the session has ended mid-drain.
///
/// ## A page for another user ends the pass
///
/// The remote is per server, and attaches whichever token the server's
/// store holds when it sends, not this session's. So a page requested as
/// one user's session ends and the next one signs in can come back as the
/// next user's. Merging it would throw, but only after its summaries were
/// recorded for this session's user, giving them another user's games
/// (#434). So every entry's `userId` is checked against [userId] before
/// any of the page is written, and a page holding anyone else's ends the
/// pass as failed.
///
/// ## The drain, then one catch-up pass
///
/// The drain asks for [limit] rows with `includeDeleted`, so it learns about
/// server-side removals too, and follows [PaginationMeta.hasMore], never a
/// short page. Like the household's, it reads every page rather than scroll
/// paging: the list renders from the cache. A session's first pass reads
/// the whole list this way; a re-run after a completed pass reads only what
/// changed since (below).
///
/// A page is a position in a list sorted newest-updated first. So a row
/// changed while the drain is paging moves onto page 1, which was already
/// read, and the drain misses it. When the drain spanned more than one page,
/// one `updatedSince` pass then asks for everything changed since the newest
/// `updatedAt` on page 1. That is the complete drain the data source's
/// dartdoc describes.
///
/// The catch-up is dated from the **server's** timestamp rather than a local
/// clock. The server filters `updatedAt >= updatedSince` against its own
/// clock, and any row changed after page 1 was read carries an `updatedAt` at
/// or after page 1's newest. A device clock would bring skew into that
/// comparison.
///
/// A single-page drain sends no catch-up. It read the whole list in one
/// response, so there was no page for a change to slip behind. A change after
/// that response is simply a change after the hydrate, for the next one to
/// find.
///
/// The catch-up pass follows `hasMore` too, and takes no catch-up of its own.
/// A change landing during it is found by the next hydrate.
///
/// ## A removal the sync drain confirms during a pass
///
/// The drain can confirm a removal while a page is in flight, and the server
/// may have answered that page before it removed the entry. Merged as read,
/// the page's live copy would bring the entry back, because the confirmation
/// purged the rows the merge compares against. So a pass reads
/// [GameCollectionRepository.removalMark] before requesting page 1 and passes
/// it with every page, the catch-up's included, and the merge skips a live
/// copy of anything confirmed removed since. The confirmation moved the
/// removal mark, so the next pass reads the whole list (below), and writes
/// the entry if it is live again by then. The merge still ends the
/// `collection` record the page's summary wrote for a skipped copy, unless
/// the user has another entry on that platform game (#469).
///
/// A confirmation, a discard that deletes a local-only entry, or a detail's
/// `forgetGame` can also land between a page's summary write and its
/// merge. If it leaves the user no entry on a platform game, it ends their
/// `collection` record for it and deletes the rows no one reads, the
/// summary's included (#469). A live entry the page holds for that platform
/// game, other than a copy the removal mark skips, then has no row to join,
/// so the merge fails and the pass ends [CollectionHydrateOutcome.failed].
/// The next pass, which reads the whole list after a failed one (below),
/// writes it.
///
/// ## A re-run reads only what changed (#450)
///
/// A session's first pass is a full drain. A pass that completes leaves a
/// delta mark: the newest `updatedAt` it saw on any page, the catch-up's and
/// tombstones included, less [deltaOverlap]. The next pass is then a delta
/// read: it asks only for rows updated since the delta mark, and otherwise runs
/// as the drain does. It sends `includeDeleted`, so a removal on the server
/// reaches the cache as a tombstone; it passes the removal mark with every
/// page; and when it spans more than one page it runs the same catch-up,
/// from its own page 1.
///
/// The next pass is a full drain instead whenever the delta mark may not
/// describe what the cache holds:
///
/// - after a pass that ended [CollectionHydrateOutcome.failed]. The
///   sections above promise that the next pass writes what a failed one
///   could not, and reading everything keeps that true without working out
///   what the failed pass reached. A failed pass clears the delta mark. A pass
///   the session check holds off never reaches [hydrate], so it leaves the
///   delta mark as it was: it read and wrote nothing;
/// - when [GameCollectionRepository.removalMark] has moved since the last
///   completed pass read it before its first request. It moves when a
///   removal is confirmed, after which a merge may have skipped a live copy
///   that the next pass is meant to write (above). Every removal this
///   device syncs is confirmed that way, so in practice the re-run after
///   one drains in full. That is accepted: it costs no more than every
///   re-run did before the delta read. It moves too when
///   [GameCollectionRepository.discardQueuedOp] leaves a row for a merge to
///   rebuild (#190): the row holds the discarded op's values, the server's
///   copy did not change, and no delta would read it. Every completed pass
///   records the one it read, whether or not the delta mark moved, so each
///   move costs one full drain rather than every pass after it.
///
/// The delta mark is the server's timestamp, for the catch-up's reason. It
/// has an overlap because the server stamps `updatedAt` before the write
/// commits, possibly on another instance, so a row can land with a stamp a
/// little older than one a pass already read. The overlap covers that and
/// ordinary clock drift between instances, nothing larger: an instance
/// whose clock runs behind another's by more than [deltaOverlap] stamps
/// rows below a mark the other set, and no delta reads them until the next
/// session's full drain. It only moves forward. A delta returns only rows
/// at or after the mark, and their newest can be older than the newest the
/// last pass saw, for a pass that re-read only the overlap or met a skewed
/// server clock's older stamps. Taken less the overlap, it would pull the
/// delta mark back, and each such pass would widen the window again. So a
/// completed pass that saw no rows, or only older ones, keeps the delta
/// mark it had.
///
/// It lives in memory, not the database. The installer builds one hydrator
/// per user session, so the mark lasts as long as the session, and each
/// session starts with a full drain. A saved mark could outlive the cache it
/// describes, after a reinstall or a cleared cache, and skip rows that cache
/// never held.
///
/// A known limit, accepted: a server change that does not move the entry's
/// `updatedAt` is read by no delta. A change to a game's title or thumbnail
/// is one. Deleting a game release is another: the database's `SET NULL`
/// clears the entry's release without the ORM restamping it. The next
/// session's full drain reads both.
///
/// ## Nothing is purged
///
/// The hydrate upserts entries and applies server tombstones. It never
/// deletes a local row the server did not mention, so the drain's
/// completeness is never load-bearing, and a delta can leave out every row
/// that did not change.
class GameCollectionHydrator {
  GameCollectionHydrator({
    required this._collection,
    required this._games,
    required this._remote,
    required this.userId,
    this.limit = GameCollectionRemoteDataSource.maxPageSize,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.collection.hydrate');

  final GameCollectionRepository _collection;
  final GameRepository _games;
  final GameCollectionRemoteDataSource _remote;
  final BgeLogger _logger;

  /// The session's user, whom every entry on a page must belong to. See the
  /// class doc.
  final String userId;

  /// Rows per request. Defaults to the server's own page-size cap.
  final int limit;

  /// How far before the newest `updatedAt` a completed pass saw, the next
  /// pass's delta read starts (#450).
  ///
  /// The server stamps `updatedAt` from its own process clock before the
  /// write commits, and there may be more than one server instance. So a
  /// row can commit with a stamp slightly older than one a pass has already
  /// read. A delta that re-reads a minute of rows costs little, and the
  /// merge is safe to repeat.
  static const Duration deltaOverlap = Duration(minutes: 1);

  /// Where the next pass's delta read starts: the newest `updatedAt` a
  /// completed pass saw, less [deltaOverlap] (the delta mark). Null until a
  /// pass completes having seen a row, and again once one fails. See the
  /// class doc.
  DateTime? _deltaSince;

  /// The [GameCollectionRepository.removalMark] the last completed pass
  /// read before its first request. A pass that reads another drains in
  /// full. See the class doc.
  int? _lastRemovalMark;

  /// Drains the user's collection into the cache: all of it, or after a
  /// completed pass only what changed since. See the class doc.
  ///
  /// Never throws — see the class doc.
  ///
  /// Not single-flight: the caller, `HydratePass`, runs one at a time (#302).
  Future<CollectionHydrateOutcome> hydrate() async {
    final int removalMark;
    try {
      removalMark = await _collection.removalMark();
    } on Object catch (error, stackTrace) {
      // A disposed repository, in practice; every write after it would fail
      // the same way. See the class doc.
      _logger.warn(
        'Collection hydrate could not read the cache before starting',
        error: error,
        stackTrace: stackTrace,
      );
      return _failed();
    }

    // A delta only while the removal mark has not moved since the last
    // completed pass read it. See the class doc.
    final since = removalMark == _lastRemovalMark ? _deltaSince : null;
    final drain = await _drain(
      query: since == null ? 'drain' : 'delta',
      updatedSince: since,
      removalsSince: removalMark,
    );
    if (drain == null) return _failed();

    var newest = drain.newest;
    final onPageOne = drain.newestOnPageOne;
    if (drain.pages > 1 && onPageOne != null) {
      final catchUp = await _drain(
        query: 'catch-up',
        updatedSince: onPageOne,
        removalsSince: removalMark,
      );
      if (catchUp == null) return _failed();
      newest = _later(newest, catchUp.newest);
    }

    // Recorded whether or not the delta mark moves, so each move of the removal
    // mark costs one full drain rather than every pass after it.
    _lastRemovalMark = removalMark;
    _deltaSince = _later(_deltaSince, newest?.subtract(deltaOverlap));
    return CollectionHydrateOutcome.complete;
  }

  /// Ends a pass as failed, and leaves the next to read everything. See the
  /// class doc.
  CollectionHydrateOutcome _failed() {
    _deltaSince = null;
    return CollectionHydrateOutcome.failed;
  }

  /// Reads every page of one query and writes each row. [query] names the
  /// query in the log: `'drain'`, `'delta'` or `'catch-up'`.
  ///
  /// Returns how many pages it read, the newest `updatedAt` on page 1, and
  /// the newest on any page, tombstones included; or null when it ended on a
  /// failure.
  Future<({int pages, DateTime? newestOnPageOne, DateTime? newest})?> _drain({
    required String query,
    DateTime? updatedSince,
    required int removalsSince,
  }) async {
    DateTime? newestOnPageOne;
    DateTime? newest;
    var page = 1;

    while (true) {
      final PaginatedResult<GameCollectionWithSummary> result;
      try {
        result = await _remote.fetchCollectionPage(
          page: page,
          limit: limit,
          includeDeleted: true,
          updatedSince: updatedSince,
        );
      } on Object catch (error, stackTrace) {
        // `Object`, not `GameCollectionRemoteException`: the data source
        // throws ArgumentError for paging it rejects locally, outside its own
        // taxonomy. User-session activate is the retry point.
        _logger.warn(
          'Collection hydrate stopped on a failed page',
          error: error,
          stackTrace: stackTrace,
          context: {'pass': query, 'page': page, 'limit': limit},
        );
        return null;
      }

      final foreign = result.items
          .where((item) => item.entry.userId != userId)
          .length;
      if (foreign > 0) {
        // Counted, not named: no user id is written to this log channel.
        _logger.warn(
          "Collection hydrate stopped on a page holding another user's "
          'entries',
          context: {
            'pass': query,
            'page': page,
            'limit': limit,
            'foreignEntries': foreign,
          },
        );
        return null;
      }

      final newestOnPage = _newest(result.items);
      if (page == 1) newestOnPageOne = newestOnPage;
      newest = _later(newest, newestOnPage);

      try {
        await _cache(result.items, removalsSince: removalsSince);
      } on Object catch (error, stackTrace) {
        // A disposed repository is a real fault, but not one to throw from
        // here. See the class doc.
        _logger.warn(
          'Collection hydrate stopped on a failed cache write',
          error: error,
          stackTrace: stackTrace,
          context: {'pass': query, 'page': page, 'limit': limit},
        );
        return null;
      }

      if (!result.meta.hasMore) {
        return (pages: page, newestOnPageOne: newestOnPageOne, newest: newest);
      }

      // `hasMore` past the server's own last page is an envelope that
      // contradicts itself. Following it would walk to the page-depth
      // ceiling, so stop on the server's count, as the household drain does.
      if (page >= result.meta.totalPages) {
        _logger.warn(
          'Collection list reports another page past its own last page; '
          'ending the hydrate.',
          context: {
            'pass': query,
            'page': page,
            'totalPages': result.meta.totalPages,
            'total': result.meta.total,
          },
        );
        return null;
      }

      page++;
    }
  }

  /// Writes one page: its summaries, then its entries. See the class doc
  /// for why that order.
  ///
  /// A tombstone's summary is skipped. Merging a tombstone only ever
  /// deletes, so its entry needs no parent row, and writing one would cache
  /// a game for every entry the user has ever removed.
  Future<void> _cache(
    List<GameCollectionWithSummary> items, {
    required int removalsSince,
  }) async {
    await _games.cachePlatformGameSummaries([
      for (final (:entry, :summary) in items)
        if (!entry.isDeleted) summary,
    ]);
    await _collection.mergeFromServer([
      for (final (:entry, summary: _) in items) entry,
    ], removalsSince: removalsSince);
  }

  /// The newest `updatedAt` among [items], or null for an empty page.
  ///
  /// The server sorts newest first, so this is the first row, but taking the
  /// maximum does not depend on that.
  static DateTime? _newest(List<GameCollectionWithSummary> items) {
    DateTime? newest;
    for (final (:entry, summary: _) in items) {
      final at = entry.updatedAt;
      if (newest == null || at.isAfter(newest)) newest = at;
    }
    return newest;
  }

  /// The later of [a] and [b], or whichever is set, or null when neither
  /// is.
  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.isAfter(a) ? b : a;
  }
}
