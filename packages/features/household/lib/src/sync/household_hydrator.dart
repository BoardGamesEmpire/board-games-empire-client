import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// What one [HouseholdHydrator.hydrate] pass achieved.
///
/// The distinction that matters is **completeness**, not success: only
/// [complete] licenses a purge of the households the server did not return
/// (#268). The other two both mean "the cache holds at least what it held
/// before, and possibly more" — which is safe to display and unsafe to
/// reconcile against.
enum HydrateOutcome {
  /// The drain finished: this is every household the server would return
  /// for this user, so absence from it is meaningful.
  complete,

  /// The response looked admin-scoped and was truncated to page 1
  /// deliberately. The cache was updated; the set is **not** complete.
  adminScoped,

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
/// ## The drain, and why the loop looks redundant
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
/// runs at most once, because `hasMore` can only be true when
/// `total > limit`, which is exactly the admin-scope degrade below. The loop
/// is still written as a loop: it is the correct general shape, it costs
/// nothing, it is what survives when backend#364 deletes the degrade, and it
/// is the only thing standing between us and a silent truncation if the cap
/// ever moves. Its multi-page behaviour is pinned by tests that inject a
/// smaller [limit].
///
/// ## The admin-scope degrade
///
/// `GET /households` widens by role: an admin's response is every household
/// on the server, which on a public instance could be thousands. The
/// client's read gate is membership-based, so none of them would ever be
/// displayed — but draining them is thousands of requests and a cache full
/// of rows nobody reads.
///
/// A first page whose `total` exceeds the server's page-size cap is treated
/// as that response: page 1 is kept, the drain stops, the outcome is
/// [HydrateOutcome.adminScoped], and a breadcrumb is logged.
///
/// This is a **guess about which query ran**, not a determination — `total`
/// is the only signal the endpoint offers. backend#364 (a membership-scoped
/// list) is what removes the guess, and this branch is **deleted outright**
/// when it lands, not reworked.
///
/// The determination is made once, against the server's real cap
/// ([HouseholdRemoteDataSource.maxPageSize]) rather than against [limit]:
/// an injected smaller limit is ordinary paging, and treating its second
/// page as an admin response would truncate a legitimate member-scoped
/// drain.
///
/// Caching an admin's extra rows is not a correctness problem — the cache
/// writers are user-agnostic by contract and the read gate enforces
/// visibility. It is purely a cost problem.
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

  /// Rows per request. Defaults to the server's own page-size cap; a
  /// smaller value is ordinary paging and does not trip the admin degrade.
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
  /// Overlap was very likely benign — the cache writers are upserts and a
  /// household is written before its members — but #300 asked for that to
  /// be recorded rather than assumed, and a guard is cheaper than the
  /// proof and keeps holding as the drain grows.
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

      final adminScoped =
          page == 1 &&
          result.meta.total > HouseholdRemoteDataSource.maxPageSize;

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

      if (adminScoped) {
        _logger.warn(
          'Household list looks admin-scoped; keeping page 1 only and '
          'skipping the drain. The cached set is NOT complete, so nothing '
          'may purge against it (#267, backend#364).',
          context: {
            'total': result.meta.total,
            'limit': result.meta.limit,
            'cap': HouseholdRemoteDataSource.maxPageSize,
          },
        );
        return HydrateOutcome.adminScoped;
      }

      if (!result.meta.hasMore) return HydrateOutcome.complete;

      // `hasMore` past the last page the server itself counted is a
      // self-contradictory envelope, and below the admin-degrade threshold
      // nothing else would stop the drain: it would walk to the server's
      // page-depth ceiling and be terminated ~1000 wasted requests later by
      // the ArgumentError the catch above now absorbs. Terminating on the
      // server's own count keeps the loop bounded by data rather than by an
      // error, and the set cannot be certified complete when the envelope
      // disagrees with itself.
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

  /// Writes one page through the user-agnostic cache writers.
  ///
  /// The household lands before its members: the members table carries a
  /// foreign key onto it, so the reverse order would fail the insert.
  Future<void> _cache(List<HouseholdWithMembers> items) async {
    for (final item in items) {
      await _repo.cacheHousehold(item.household);
      if (item.members.isNotEmpty) await _repo.cacheMembers(item.members);
    }
  }
}
