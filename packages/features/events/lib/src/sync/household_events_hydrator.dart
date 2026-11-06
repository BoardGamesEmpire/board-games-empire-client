import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'page_one.dart';

/// What one [HouseholdEventsHydrator.hydrate] pass achieved (#503).
///
/// As with the user's own list, what matters is how much of the household's
/// list the server's answer vouched for, because only that licenses a purge.
/// After any outcome but [failed], every page the server sent was cached.
enum HouseholdEventsOutcome {
  /// Page 1 was the whole list: one consistent read of every upcoming event
  /// the household shows this user, so absence from it is meaningful. Every
  /// household event it didn't name was purged.
  complete,

  /// Every page was cached, and nothing was purged: the list ran past page 1,
  /// or page 1 was its only page and sent fewer events than it counts.
  drained,

  /// The server answered that the household is missing or deleted: a 404
  /// carrying its error envelope, on whichever page asked. Every household
  /// event the pass could purge was purged.
  notFound,

  /// The pass ended early on a failure. It keeps every page it wrote, and
  /// purged nothing.
  failed,
}

/// Pulls one household's upcoming events from `GET /households/:id/events`
/// into the per-user cache, under the `household` access source, and removes
/// the ones the household stopped listing (#503).
///
/// The household screen lists them from the cache, so they show offline, and
/// a row opens a detail that has the event already. The list is the server's:
/// an event cancelled, archived, or moved back to choosing a date leaves it,
/// and a cached row that stayed would go on listing it.
///
/// ## It never throws
///
/// `HydratePass` catches a drain that throws, but only as a backstop: the
/// failure is logged as an error that escaped, with nothing to say which page
/// or write failed, and the pass has no outcome to report. So [hydrate] reports
/// failure in its return value, which the screen reads from its status, and
/// catches by [Object]: an [EventRemoteException], the [ArgumentError] the data
/// source raises for an id or paging it rejects locally, and the [StateError]
/// the repository throws once the session has ended mid-drain. A
/// [confirmSession] that throws is caught too, though
/// `SessionIdentityGuard.confirm`, which backs it, never does.
///
/// ## The drain
///
/// Request [limit] rows and follow [PaginationMeta.hasMore], as
/// `EventHydrator` does, so the section can show every upcoming event the
/// household lists.
///
/// ## What a pass removes
///
/// Only the current user's `household` access to this household's events,
/// through [EventRepository.purgeHouseholdEventsAbsentFrom]. Their
/// `attending` and `read` access stay, and so does every other user's. An
/// event no user can read any more leaves the cache.
///
/// **Of a household that answers, only a whole page 1 licenses a purge.** The
/// list is ordered by soonest confirmed date, then id, and page 1 is one
/// REPEATABLE READ snapshot of it. A walk across pages is not: dates pass and
/// move between requests, so an event can shift past a page boundary unseen and
/// read as absent. Unlike the user's own list, ordered by creation, page 1
/// vouches for no range short of the whole list either: an event's date can
/// move where its creation can't, so one missing from page 1's range may only
/// have moved past it. So the purge runs only when page 1 says it is the last
/// page, and only after [judgeWholeList] finds it whole
/// ([HouseholdEventsOutcome.complete]). One that contradicts itself fails the
/// pass, and one short of its count ends [HouseholdEventsOutcome.drained].
/// Neither purges.
///
/// The accepted cost: a household listing more than [limit] upcoming events,
/// 100 by default, never purges, so an event it stopped listing stays in its
/// section until the list fits on one page. The section still drops an event
/// whose dates have ended, by its own upcoming rule.
///
/// **A missing household.** A 404 carrying the API's envelope, on any page,
/// says the household is missing or deleted, so it lists nothing. The pass
/// purges against an empty list and ends [HouseholdEventsOutcome.notFound].
/// Rows this pass already wrote are kept, as is any row written since the
/// purgeable set was read; the next pass, answered 404 on page 1, removes
/// them. Like a page, that purge waits on [confirmSession], since the 404 was
/// read as whoever held the session. Any other failure, a 403 included, fails
/// the pass and purges nothing.
///
/// The purge is limited to the events
/// [EventRepository.purgeableHouseholdEvents] named **before page 1 was
/// requested**, and to those not written since: an event cached while the
/// request was in flight, by another tab's pass say, can be missing from the
/// response and still be listed.
class HouseholdEventsHydrator {
  HouseholdEventsHydrator({
    required EventRepository repository,
    required this._remote,
    this.limit = EventRemoteDataSource.maxPageSize,
    this.confirmSession,
    BgeLogger? logger,
  }) : _repo = repository,
       _logger = logger ?? BgeLogger('bge.events.household.hydrate');

  final EventRepository _repo;
  final EventRemoteDataSource _remote;
  final BgeLogger _logger;

  /// Rows per request. Defaults to the server's own page-size cap.
  final int limit;

  /// Whether the session is still the user this cache belongs to, asked
  /// after each answer comes back and before anything is written from it
  /// (#432). Null, as on native, is always yes.
  ///
  /// On web another tab can move the shared session cookie to another user
  /// while a drain is paging, and every page read after that holds what the
  /// household shows the other user. The rows carry nothing that says whose
  /// they are, so only the session can be asked.
  final Future<bool> Function()? confirmSession;

  /// Drains [householdId]'s event list into the cache, purges what page 1
  /// licenses, and reports how much of the list that purge could judge.
  ///
  /// Never throws — see the class doc.
  ///
  /// Not single-flight: a drain deletes as well as writes, so the caller,
  /// `HouseholdEventsSync`, runs one at a time per household.
  Future<HouseholdEventsOutcome> hydrate(String householdId) async {
    final context = {'householdId': householdId};

    final Map<String, int> purgeable;
    try {
      purgeable = await _repo.purgeableHouseholdEvents(householdId);
    } on Object catch (error, stackTrace) {
      // A disposed repository, in practice; every write after it would fail
      // the same way. See the class doc.
      _logger.warn(
        'Household events hydrate could not read the cache before starting',
        error: error,
        stackTrace: stackTrace,
        context: context,
      );
      return HouseholdEventsOutcome.failed;
    }

    var page = 1;

    while (true) {
      final pageContext = {...context, 'page': page, 'limit': limit};

      final PaginatedResult<EventSnapshot> result;
      try {
        result = await _remote.fetchHouseholdEvents(
          householdId,
          page: page,
          limit: limit,
        );
      } on EventRemoteNotFoundException catch (error) {
        return _finishGone(householdId, purgeable, error, pageContext);
      } on Object catch (error, stackTrace) {
        // `Object`, not `EventRemoteException`: the data source throws
        // ArgumentError for an id or paging it rejects locally, outside its
        // own taxonomy. Nothing retries here: the screen's retry is the
        // retry point.
        _logger.warn(
          'Household events hydrate stopped on a failed page',
          error: error,
          stackTrace: stackTrace,
          context: pageContext,
        );
        return HouseholdEventsOutcome.failed;
      }

      if (!await _confirmed(pageContext)) return HouseholdEventsOutcome.failed;

      try {
        // The whole page in one write, so the section rebuilds once for it
        // rather than once per event.
        await _repo.cacheEvents(
          result.items,
          source: EventAccessSource.household,
        );
      } on Object catch (error, stackTrace) {
        _logger.warn(
          'Household events hydrate stopped on a failed cache write',
          error: error,
          stackTrace: stackTrace,
          context: pageContext,
        );
        return HouseholdEventsOutcome.failed;
      }

      if (!result.meta.hasMore) {
        if (page == 1) {
          return _finishWholeList(householdId, result, purgeable);
        }
        return HouseholdEventsOutcome.drained;
      }

      // `hasMore` past the last page the server itself counted is an
      // envelope that contradicts itself, and nothing else would stop the
      // drain until the server refused a page past its offset ceiling.
      if (page >= result.meta.totalPages) {
        _logger.warn(
          'Household event list reports another page past its own last page; '
          'ending the drain. The cached set is NOT complete.',
          context: {
            ...pageContext,
            'totalPages': result.meta.totalPages,
            'total': result.meta.total,
          },
        );
        return HouseholdEventsOutcome.failed;
      }

      page++;
    }
  }

  /// Whether the answer that just came back may be written from:
  /// [confirmSession] said yes, or there is none to ask. A no is logged.
  Future<bool> _confirmed(Map<String, Object> context) async {
    final confirm = confirmSession;
    if (confirm == null) return true;

    final bool confirmed;
    try {
      confirmed = await confirm();
    } on Object catch (error, stackTrace) {
      // The guard behind it never throws, but nothing may escape from here.
      _logger.warn(
        'Household events hydrate stopped: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
        context: context,
      );
      return false;
    }
    if (!confirmed) {
      _logger.info(
        'Household events hydrate stopped: an answer came back once the '
        'session could no longer be confirmed as this user\'s',
        context: context,
      );
    }
    return confirmed;
  }

  /// Ends a pass whose page 1 says it is the whole list, purging against it
  /// when [judgeWholeList] finds it whole.
  Future<HouseholdEventsOutcome> _finishWholeList(
    String householdId,
    PaginatedResult<EventSnapshot> pageOne,
    Map<String, int> purgeable,
  ) async {
    final meta = pageOne.meta;
    final rows = pageOne.items.length;
    final counts = {
      'householdId': householdId,
      'rows': rows,
      'page': meta.page,
      'totalPages': meta.totalPages,
      'total': meta.total,
      'limit': meta.limit,
    };
    switch (judgeWholeList(meta, rows)) {
      case WholeListVerdict.contradicts:
        _logger.warn(
          'Household event list reports page 1 as its last but contradicts '
          'itself; purging nothing. The cached set is NOT complete.',
          context: counts,
        );
        return HouseholdEventsOutcome.failed;
      case WholeListVerdict.short:
        _logger.warn(
          'Household event list sent fewer events than it counts on its only '
          'page; caching them and purging nothing.',
          context: counts,
        );
        return HouseholdEventsOutcome.drained;
      case WholeListVerdict.whole:
        final listed = {
          for (final snapshot in pageOne.items) snapshot.event.id,
        };
        return await _purge(householdId, listed, purgeable)
            ? HouseholdEventsOutcome.complete
            : HouseholdEventsOutcome.failed;
    }
  }

  /// Ends a pass the server answered with a missing household, purging
  /// against an empty list once the session is confirmed.
  Future<HouseholdEventsOutcome> _finishGone(
    String householdId,
    Map<String, int> purgeable,
    EventRemoteNotFoundException error,
    Map<String, Object> context,
  ) async {
    _logger.info(
      'Household events hydrate found the household missing or deleted',
      error: error,
      context: context,
    );
    if (!await _confirmed(context)) return HouseholdEventsOutcome.failed;
    return await _purge(householdId, const {}, purgeable)
        ? HouseholdEventsOutcome.notFound
        : HouseholdEventsOutcome.failed;
  }

  /// Removes the current user's `household` access to each event in
  /// [purgeable] that [listed] doesn't name, and logs what it removed.
  ///
  /// Returns false when the purge failed, which it logs.
  Future<bool> _purge(
    String householdId,
    Set<String> listed,
    Map<String, int> purgeable,
  ) async {
    try {
      final purged = await _repo.purgeHouseholdEventsAbsentFrom(
        householdId,
        listed,
        purgeable: purgeable,
      );
      if (purged.isNotEmpty) {
        _logger.info(
          'Household events hydrate removed the events the household no '
          'longer lists for this user',
          context: {
            'householdId': householdId,
            'eventIds': purged.toList()..sort(),
          },
        );
      }
      return true;
    } on Object catch (error, stackTrace) {
      // A cache write like any other; see the drain's.
      _logger.warn(
        'Household events hydrate could not remove the events the household '
        'no longer lists',
        error: error,
        stackTrace: stackTrace,
        context: {'householdId': householdId},
      );
      return false;
    }
  }
}
