import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What one [HouseholdHydrator.hydrate] pass achieved.
///
/// The distinction that matters is **completeness**, not success: only
/// [complete] licenses a purge of the households the server did not return
/// (#268). After either of the other two the cache still holds every
/// household it held before, which is safe to display and unsafe to
/// reconcile against.
enum HydrateOutcome {
  /// Page 1 was the whole list: one consistent read of every household the
  /// server would return for this user, so absence from it is meaningful.
  /// The pass purged against it.
  complete,

  /// Every page was cached, but across more than one request. A walk
  /// across pages is not one snapshot, so the set is **not** complete and
  /// nothing was purged.
  drained,

  /// The pass ended early on a failure. Whatever landed before it is kept.
  failed,
}

/// Pulls the user's households from the server into the local cache on
/// user-session activate (#267).
///
/// The household cache is otherwise populated only by local create, so a
/// reinstall or a second device shows an empty list while the server holds
/// the user's households. This is what makes the list real rather than
/// device-local.
///
/// ## It must never throw
///
/// This runs from user-session scope activation, which is the bootstrap
/// gate: a throw out of an installer aborts activation, and the shell
/// responds by logging, dispatching `AuthSignOutRequested` and refusing to
/// advance (see `_AuthScope._handleAuthenticated`). An escaping error would
/// therefore turn *server unreachable* into *forced sign-out*, on the exact
/// path this issue exists to fix — a reinstall on a bad connection.
///
/// So [hydrate] reports failure in its return value and swallows everything
/// else, including errors that are ordinarily worth surfacing loudly. It
/// expects a [HouseholdRemoteException], the [ArgumentError] the data source
/// raises for paging it can reject locally, and the [StateError] the
/// repository throws once its scope has been torn down mid-drain — but it
/// catches by [Object] rather than by that list, because the cost of missing
/// one is a forced sign-out.
///
/// ## The drain
///
/// Request [limit] rows and follow [PaginationMeta.hasMore] — never a short
/// page, which is not a terminator against a filtered query.
///
/// This is a **deliberate full drain, not scroll paging**. Households per
/// user are realistically single digits and the list renders reactively off
/// the local cache, so a paging UI would be unearned complexity. Stated
/// explicitly so it is not later "fixed" into paging.
///
/// At the default [limit] — the server's own page-size cap — the loop body
/// runs more than once only for a user with more households than that. The
/// list is membership-scoped for a user session (backend#417), so a large
/// `total` means exactly that and nothing else; there is no longer a
/// role-widened response to guess at and stop early for.
///
/// ## What a pass removes (#268)
///
/// The cache is otherwise add-only, so without this a household the user
/// left, or was removed from, on another device stays on this one's list.
///
/// **Rosters, on every pass.** Each household is written with the roster
/// the list embeds, and the repository makes the cached roster match it
/// ([HouseholdRepository.cacheHouseholdWithRoster]). This does not depend
/// on the pass finishing: the server reads each row and its roster
/// together. A roster the repository will not trust to say who left is
/// merged in instead, and logged here.
///
/// **Households, only after a snapshot.** The server's own contract is that
/// only a first page with `hasMore: false` is one consistent read. A walk
/// across pages can carry a live household past a page boundary unseen, so
/// a multi-page drain caches every page and purges nothing
/// ([HydrateOutcome.drained]). A user above one page of households keeps
/// the stale window they always had.
///
/// The purge is limited to the households
/// [HouseholdRepository.purgeableHouseholdIds] named **before page 1 was
/// requested**: a household created while the request was in flight can be
/// missing from the response without having gone anywhere. A first page
/// whose envelope counts more than one page purges nothing either.
class HouseholdHydrator {
  HouseholdHydrator({
    required HouseholdRepository repository,
    required this._remote,
    this.limit = HouseholdRemoteDataSource.maxPageSize,
    BgeLogger? logger,
  }) : _repo = repository,
       _logger = logger ?? BgeLogger('bge.household.hydrate');

  final HouseholdRepository _repo;
  final HouseholdRemoteDataSource _remote;
  final BgeLogger _logger;

  /// Rows per request. Defaults to the server's own page-size cap.
  final int limit;

  /// Drains the household list into the cache, and reports whether the
  /// result is a complete set.
  ///
  /// Never throws — see the class doc.
  ///
  /// **Single-flight** (#302 D3): a call made while a pass is in flight
  /// joins that pass and receives its outcome, rather than starting a
  /// second drain. Until #302 there was exactly one caller, so this was a
  /// question nobody had to answer; the re-hydrate trigger and #300's
  /// manual retry both add callers that can fire while the install-time
  /// pass (#267 D2, started unawaited) is still running.
  ///
  /// Overlap was very likely benign while the cache writers only upserted,
  /// but #300 asked for that to be recorded rather than assumed, and a
  /// guard is cheaper than the proof and keeps holding as the drain grows.
  /// It has since grown: a pass now deletes (#268), and one pass's purge
  /// racing another's writes is a question this guard means nobody has to
  /// answer.
  ///
  /// This is a concurrency guard, **not a cache**: once a pass settles the
  /// next call asks the server again, which is the whole point of #302.
  Future<HydrateOutcome> hydrate() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final pass = _drain();
    _inFlight = pass;
    // Identity-checked so a pass cannot clear its successor. Today a
    // successor can only be created after this clear runs, but the check
    // costs nothing and does not depend on that staying true.
    return pass.whenComplete(() {
      if (identical(_inFlight, pass)) _inFlight = null;
    });
  }

  /// The pass currently draining, or null when none is.
  Future<HydrateOutcome>? _inFlight;

  Future<HydrateOutcome> _drain() async {
    final Set<String> purgeable;
    try {
      purgeable = await _repo.purgeableHouseholdIds();
    } on Object catch (error, stackTrace) {
      // A disposed repository, in practice; every write after it would fail
      // the same way. See the class doc.
      _logger.warn(
        'Household hydrate could not read the cache before starting',
        error: error,
        stackTrace: stackTrace,
      );
      return HydrateOutcome.failed;
    }
    var page = 1;

    while (true) {
      final PaginatedResult<HouseholdWithMembers> result;
      try {
        result = await _remote.fetchHouseholds(page: page, limit: limit);
      } on Object catch (error, stackTrace) {
        // Deliberately `Object`, not `HouseholdRemoteException`: the data
        // source validates paging locally and throws **ArgumentError** —
        // outside its own taxonomy — before spending a round trip. A
        // narrower catch would let that escape, and the one thing this
        // class must never do is throw.
        //
        // Transient and permanent are logged the same and neither retries
        // here: user-session activate is the retry point, and #266 D4
        // classifies a list 404 transient precisely so a routing fault does
        // not end hydration for the life of the process.
        _logger.warn(
          'Household hydrate stopped on a failed page',
          error: error,
          stackTrace: stackTrace,
          context: {'page': page, 'limit': limit},
        );
        return HydrateOutcome.failed;
      }

      try {
        await _cache(result.items);
      } on Object catch (error, stackTrace) {
        // Ordinarily worth rethrowing — a disposed repository is a real
        // fault — but not out of here. See the class doc.
        _logger.warn(
          'Household hydrate stopped on a failed cache write',
          error: error,
          stackTrace: stackTrace,
          context: {'page': page, 'limit': limit},
        );
        return HydrateOutcome.failed;
      }

      if (!result.meta.hasMore) {
        if (page > 1) return HydrateOutcome.drained;
        // The purge deletes whatever page 1 leaves out, so `hasMore` alone
        // does not license it: the rest of the envelope must also say there
        // is one page. The row count is not compared with `total`. The
        // server may filter rows after counting, so a short page is valid.
        if (result.meta.totalPages > 1 ||
            result.meta.total > result.meta.limit) {
          _logger.warn(
            'Household list reports page 1 as its last but counts more than '
            'one page; purging nothing. The cached set is NOT complete.',
            context: {
              'totalPages': result.meta.totalPages,
              'total': result.meta.total,
              'limit': result.meta.limit,
            },
          );
          return HydrateOutcome.failed;
        }
        try {
          final purged = await _repo.purgeHouseholdsAbsentFrom({
            for (final item in result.items) item.household.id,
          }, purgeable: purgeable);
          if (purged.isNotEmpty) {
            _logger.info(
              'Household hydrate removed households the server no longer '
              'lists for this user',
              context: {'householdIds': purged.toList()..sort()},
            );
          }
        } on Object catch (error, stackTrace) {
          // A cache write like any other; see the one above.
          _logger.warn(
            'Household hydrate could not purge against a complete snapshot',
            error: error,
            stackTrace: stackTrace,
          );
          return HydrateOutcome.failed;
        }
        return HydrateOutcome.complete;
      }

      // `hasMore` past the last page the server itself counted is a
      // self-contradictory envelope, and nothing else would stop the
      // drain: it would walk to the server's page-depth ceiling and be
      // terminated ~1000 wasted requests later by the ArgumentError the
      // catch above now absorbs. Terminating on the server's own count
      // keeps the loop bounded by data rather than by an error, and the set
      // cannot be certified complete when the envelope disagrees with
      // itself.
      if (page >= result.meta.totalPages) {
        _logger.warn(
          'Household list reports another page past its own last page; '
          'ending the drain. The cached set is NOT complete.',
          context: {
            'page': page,
            'totalPages': result.meta.totalPages,
            'total': result.meta.total,
            'limit': result.meta.limit,
          },
        );
        return HydrateOutcome.failed;
      }

      page++;
    }
  }

  /// Writes one page, each household with the roster the list embedded.
  Future<void> _cache(List<HouseholdWithMembers> items) async {
    for (final item in items) {
      final write = await _repo.cacheHouseholdWithRoster(
        item.household,
        item.members,
      );
      if (write == HouseholdRosterWrite.merged) {
        // Every household in a membership-scoped list has the caller on its
        // roster, so this one arrived without its roster in full: most
        // likely a response that dropped the `members` include.
        _logger.warn(
          'Household arrived without a roster that includes the current '
          'user; merged it rather than removing anyone',
          context: {
            'householdId': item.household.id,
            'rosterSize': item.members.length,
          },
        );
      }
    }
  }
}
