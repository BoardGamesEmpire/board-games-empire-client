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
/// ## The drain, then one catch-up pass
///
/// The drain asks for [limit] rows with `includeDeleted`, so it learns about
/// server-side removals too, and follows [PaginationMeta.hasMore], never a
/// short page. Like the household's, it is a deliberate full drain rather
/// than scroll paging: the list renders from the cache.
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
/// ## Nothing is purged
///
/// The hydrate upserts entries and applies server tombstones. It never
/// deletes a local row the server did not mention, so the drain's
/// completeness is never load-bearing.
class GameCollectionHydrator {
  GameCollectionHydrator({
    required this._collection,
    required this._games,
    required this._remote,
    this.limit = GameCollectionRemoteDataSource.maxPageSize,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.collection.hydrate');

  final GameCollectionRepository _collection;
  final GameRepository _games;
  final GameCollectionRemoteDataSource _remote;
  final BgeLogger _logger;

  /// Rows per request. Defaults to the server's own page-size cap.
  final int limit;

  /// Drains the user's collection into the cache.
  ///
  /// Never throws — see the class doc.
  ///
  /// **Single-flight:** a call made while a pass is in flight joins that
  /// pass and receives its outcome, as `HouseholdHydrator.hydrate` does.
  /// Once a pass settles, the next call asks the server again.
  Future<CollectionHydrateOutcome> hydrate() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final pass = _pass();
    _inFlight = pass;
    return pass.whenComplete(() {
      if (identical(_inFlight, pass)) _inFlight = null;
    });
  }

  /// The pass currently running, or null when none is.
  Future<CollectionHydrateOutcome>? _inFlight;

  Future<CollectionHydrateOutcome> _pass() async {
    final drain = await _drain();
    if (drain == null) return CollectionHydrateOutcome.failed;

    final since = drain.newestOnPageOne;
    if (drain.pages == 1 || since == null) {
      return CollectionHydrateOutcome.complete;
    }

    final catchUp = await _drain(updatedSince: since);
    return catchUp == null
        ? CollectionHydrateOutcome.failed
        : CollectionHydrateOutcome.complete;
  }

  /// Reads every page of one query and writes each row.
  ///
  /// Returns how many pages it read and the newest `updatedAt` on page 1, or
  /// null when it ended on a failure.
  Future<({int pages, DateTime? newestOnPageOne})?> _drain({
    DateTime? updatedSince,
  }) async {
    final pass = updatedSince == null ? 'drain' : 'catch-up';
    DateTime? newestOnPageOne;
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
          context: {'pass': pass, 'page': page, 'limit': limit},
        );
        return null;
      }

      if (page == 1) newestOnPageOne = _newest(result.items);

      try {
        await _cache(result.items);
      } on Object catch (error, stackTrace) {
        // A disposed repository is a real fault, but not one to throw from
        // here. See the class doc.
        _logger.warn(
          'Collection hydrate stopped on a failed cache write',
          error: error,
          stackTrace: stackTrace,
          context: {'pass': pass, 'page': page, 'limit': limit},
        );
        return null;
      }

      if (!result.meta.hasMore) {
        return (pages: page, newestOnPageOne: newestOnPageOne);
      }

      // `hasMore` past the server's own last page is an envelope that
      // contradicts itself. Following it would walk to the page-depth
      // ceiling, so stop on the server's count, as the household drain does.
      if (page >= result.meta.totalPages) {
        _logger.warn(
          'Collection list reports another page past its own last page; '
          'ending the hydrate.',
          context: {
            'pass': pass,
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
  Future<void> _cache(List<GameCollectionWithSummary> items) async {
    await _games.cachePlatformGameSummaries([
      for (final (:entry, :summary) in items)
        if (!entry.isDeleted) summary,
    ]);
    await _collection.mergeFromServer([
      for (final (:entry, summary: _) in items) entry,
    ]);
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
}
