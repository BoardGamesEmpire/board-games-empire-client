import 'package:di/di.dart' show LocalClockService;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../support/fake_event_remote.dart';

class _MockBgeLogger extends Mock implements BgeLogger {}

/// [cache], except that its purge fails, as a database error would. A pass
/// calls nothing else.
class _PurgeFails implements EventRepository {
  _PurgeFails(this.cache);

  final EventRepository cache;

  /// Whether the pass got as far as the purge.
  var purgeAsked = false;

  @override
  Future<Map<String, int>> purgeableAttendance() => cache.purgeableAttendance();

  @override
  Future<void> cacheEvents(
    List<EventSnapshot> snapshots, {
    required EventAccessSource source,
  }) => cache.cacheEvents(snapshots, source: source);

  @override
  Future<Set<String>> purgeAttendanceAbsentFrom(
    Set<String> snapshotIds, {
    required Map<String, int> purgeable,
    DateTime? newerThan,
  }) async {
    purgeAsked = true;
    throw StateError('the database is gone');
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not in a hydrate');
}

const _kUserId = 'user-abc';

/// The event [id] as the list returns it, created [minute] minutes past a
/// fixed hour, so a higher [minute] sorts nearer the top of the list. No
/// roster, since the list carries none.
EventSnapshot _row(String id, int minute) {
  final createdAt = DateTime.utc(2026, 10, 1, 12, minute);
  return EventSnapshot(
    event: Event(
      id: id,
      title: 'Event $id',
      createdById: 'user-host',
      type: EventType.casualGathering,
      reach: Reach.friends,
      status: EventStatus.scheduled,
      schedulingMode: EventSchedulingMode.fixed,
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
    occurrences: const [],
  );
}

/// One page of [rows]. [total] defaults to the rows sent, and [totalPages] to
/// what the server derives from [total] and [limit], so pass [totalPages]
/// only to build an envelope that contradicts itself.
PaginatedResult<EventSnapshot> _page(
  List<EventSnapshot> rows, {
  int page = 1,
  int limit = 100,
  int? total,
  int? totalPages,
  bool hasMore = false,
}) {
  final count = total ?? rows.length;
  return PaginatedResult(
    items: rows,
    meta: PaginationMeta(
      page: page,
      limit: limit,
      total: count,
      totalPages: totalPages ?? (count / limit).ceil(),
      hasMore: hasMore,
    ),
  );
}

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl repository;

  /// The user's repository over [db], with a queue of its own over the same
  /// database, as the session scope wires it.
  EventRepositoryImpl openRepository() => EventRepositoryImpl(
    db,
    userId: _kUserId,
    syncQueue: SyncQueueRepositoryImpl(
      db,
      const LocalClockService(),
      userId: _kUserId,
    ),
    clock: const LocalClockService(),
  );

  setUp(() {
    db = inMemoryServerDatabase();
    repository = openRepository();
  });

  tearDown(() async => db.close());

  EventHydrator build(
    FakeEventRemote remote, {
    int limit = EventRemoteDataSource.maxPageSize,
    Future<bool> Function()? confirmSession,
    BgeLogger? logger,
  }) => EventHydrator(
    repository: repository,
    remote: remote,
    limit: limit,
    confirmSession: confirmSession,
    logger: logger,
  );

  /// Caches [snapshot] as attended, as an earlier pass would have.
  Future<void> attend(EventSnapshot snapshot) =>
      repository.cacheEvent(snapshot, source: EventAccessSource.attending);

  /// The ids of the events this user attends, in the list's order.
  Future<List<String>> attending() async => [
    for (final event in await repository.watchAttendingEvents().first) event.id,
  ];

  /// A fresh repository over the same database, as the next session opens
  /// one, to read the cache back once [repository] has been disposed.
  EventRepositoryImpl nextSession() => openRepository();

  group('what a pass writes (#496)', () {
    test('a page at a time, so a live list changes once a page', () async {
      // A list screen watches the cache while a pass drains it. Written an
      // event at a time, the list would rebuild once per event on every
      // pass, and show each page half written.
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-5', 50), _row('e-4', 40), _row('e-3', 30)],
          limit: 3,
          total: 5,
          hasMore: true,
        ),
        _page([_row('e-2', 20), _row('e-1', 10)], page: 2, limit: 3, total: 5),
      ]);
      final listed = <List<String>>[];
      final watching = repository.watchAttendingEvents().listen(
        (events) => listed.add([for (final event in events) event.id]),
      );
      addTearDown(watching.cancel);
      await pumpEventQueue();

      expect(
        await build(remote, limit: 3).hydrate(),
        EventHydrateOutcome.windowed,
      );
      await pumpEventQueue();

      expect(listed, [
        <String>[],
        ['e-5', 'e-4', 'e-3'],
        ['e-5', 'e-4', 'e-3', 'e-2', 'e-1'],
      ]);
    });
  });

  group('what a pass removes (#496)', () {
    test(
      'one page: caches every event and purges the ones it no longer lists',
      () async {
        await attend(_row('e-stale', 30));
        final remote = FakeEventRemote.pages([
          _page([_row('e-2', 20), _row('e-1', 10)]),
        ]);

        // Its defaults: the server's page-size cap, and no session to check,
        // as on native.
        final outcome = await EventHydrator(
          repository: repository,
          remote: remote,
        ).hydrate();

        expect(outcome, EventHydrateOutcome.complete);
        expect(await repository.getEvent('e-stale'), isNull);
        expect(await attending(), ['e-2', 'e-1']);
        expect(remote.requests, [(page: 1, limit: 100)]);
      },
    );

    test('several pages: caches every page and purges only within page 1\'s '
        'range', () async {
      // Page 1 ends on e-5, created at minute 50.
      await attend(_row('e-stale-newer', 55));
      await attend(_row('e-stale-older', 35));
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-6', 60), _row('e-5', 50)],
          limit: 2,
          total: 5,
          hasMore: true,
        ),
        _page(
          [_row('e-4', 40), _row('e-3', 30)],
          page: 2,
          limit: 2,
          total: 5,
          hasMore: true,
        ),
        _page([_row('e-2', 20)], page: 3, limit: 2, total: 5),
      ]);

      final outcome = await build(remote, limit: 2).hydrate();

      expect(outcome, EventHydrateOutcome.windowed);
      expect(
        await repository.getEvent('e-stale-newer'),
        isNull,
        reason: 'it sorts within page 1, which does not name it',
      );
      expect(
        await repository.getEvent('e-stale-older'),
        isNotNull,
        reason: 'it sorts below page 1, and no later page is a snapshot',
      );
      expect(await attending(), [
        'e-6',
        'e-5',
        'e-4',
        'e-stale-older',
        'e-3',
        'e-2',
      ]);
    });

    test('a short first page that says it has more purges nothing', () async {
      // The API fills a first page that has more to follow, so a short one
      // came through a proxy or was cut off, and need not hold every event
      // that sorts within its range.
      await attend(_row('e-stale', 45));
      final remote = FakeEventRemote.pages([
        _page([_row('e-4', 40)], limit: 2, total: 3, hasMore: true),
        _page([_row('e-2', 20)], page: 2, limit: 2, total: 3),
      ]);

      final outcome = await build(remote, limit: 2).hydrate();

      expect(outcome, EventHydrateOutcome.drained);
      expect(await attending(), ['e-stale', 'e-4', 'e-2']);
    });

    test('a first page that says it has more past its own last page fails and '
        'purges nothing', () async {
      // Full and numbered 1, so it would license a window if its envelope
      // agreed with itself. It counts one page and says another follows.
      await attend(_row('e-stale', 55));
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-6', 60), _row('e-5', 50)],
          limit: 2,
          total: 2,
          hasMore: true,
        ),
      ]);

      final outcome = await build(remote, limit: 2).hydrate();

      expect(outcome, EventHydrateOutcome.failed);
      expect(await repository.getEvent('e-stale'), isNotNull);
      expect(remote.requests, [(page: 1, limit: 2)]);
    });

    test('an empty first page that claims to be full purges nothing', () async {
      // Its envelope counts a limit of zero, so no rows at all are as many as
      // the limit, and there is no last row to bound a window by.
      await attend(_row('e-stale', 30));
      final remote = FakeEventRemote.pages([
        _page(const [], limit: 0, total: 1, totalPages: 2, hasMore: true),
        _page([_row('e-1', 10)], page: 2, limit: 0, total: 1, totalPages: 2),
      ]);

      expect(await build(remote).hydrate(), EventHydrateOutcome.drained);
      expect(await attending(), ['e-stale', 'e-1']);
    });

    test('a first page numbered as another page purges nothing', () async {
      // Full, and more follow, but the answer to page 1 says it is page 2,
      // so it is no proof of what sorts at the top of the list.
      await attend(_row('e-stale', 55));
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-6', 60), _row('e-5', 50)],
          page: 2,
          limit: 2,
          total: 3,
          hasMore: true,
        ),
        _page([_row('e-4', 40)], page: 2, limit: 2, total: 3),
      ]);

      final outcome = await build(remote, limit: 2).hydrate();

      expect(outcome, EventHydrateOutcome.drained);
      expect(await repository.getEvent('e-stale'), isNotNull);
    });

    group('a full first page whose counts disagree purges nothing', () {
      // Full, numbered 1, and more follow, so only its counts give it away.
      // The server counts `total` in the same read as the rows and derives
      // the pages from it, so a first page of a longer list counts more
      // events than it holds, in as many pages as that makes.
      final counts = {
        'when it counts fewer events than it sent': (total: 1, totalPages: 2),
        'when it counts other than the pages its total makes': (
          total: 5,
          totalPages: 4,
        ),
      };
      for (final MapEntry(key: disagreement, value: (:total, :totalPages))
          in counts.entries) {
        test(disagreement, () async {
          // Inside page 1's range, so a windowed purge would take it.
          await attend(_row('e-stale', 55));
          final remote = FakeEventRemote.pages([
            _page(
              [_row('e-6', 60), _row('e-5', 50)],
              limit: 2,
              total: total,
              totalPages: totalPages,
              hasMore: true,
            ),
            _page(
              [_row('e-4', 40)],
              page: 2,
              limit: 2,
              total: total,
              totalPages: totalPages,
            ),
          ]);

          final outcome = await build(remote, limit: 2).hydrate();

          expect(outcome, EventHydrateOutcome.drained);
          expect(await repository.getEvent('e-stale'), isNotNull);
        });
      }
    });

    group('a single page that contradicts itself fails and purges nothing', () {
      // A page that says it is the last one licenses removing whatever it
      // leaves out, so the rest of its envelope must agree that it is the
      // whole list, or the pass fails.
      final envelopes = {
        'counts more than one page': _page([_row('e-1', 10)], totalPages: 2),
        'is numbered as another page': _page([_row('e-1', 10)], page: 2),
        'sends more events than it counts': _page([
          _row('e-1', 10),
          _row('e-0', 5),
        ], total: 1),
        // Rows and count agree, and it counts one page, so only its limit
        // gives it away: two events don't fit a page of one.
        'counts more events than a page holds': _page(
          [_row('e-1', 10), _row('e-0', 5)],
          limit: 1,
          total: 2,
          totalPages: 1,
        ),
      };
      for (final MapEntry(key: contradiction, value: envelope)
          in envelopes.entries) {
        test('when it $contradiction', () async {
          await attend(_row('e-stale', 30));
          final remote = FakeEventRemote.pages([envelope]);

          expect(await build(remote).hydrate(), EventHydrateOutcome.failed);
          expect(await repository.getEvent('e-stale'), isNotNull);
          expect(await repository.getEvent('e-1'), isNotNull);
        });
      }
    });

    test('an emptied list purges every attending event', () async {
      // The user left the last event they attended. An empty page counts no
      // pages, and it is still the whole list.
      await attend(_row('e-2', 20));
      await attend(_row('e-1', 10));
      final remote = FakeEventRemote.pages([_page(const [])]);

      expect(await build(remote).hydrate(), EventHydrateOutcome.complete);
      expect(await attending(), isEmpty);
    });

    test('a single page that sends fewer events than it counts purges '
        'nothing', () async {
      // Counted in the same read as the rows, so an event it counts and did
      // not send is one the user may still attend.
      await attend(_row('e-stale', 30));
      final remote = FakeEventRemote.pages([
        _page([_row('e-1', 10)], total: 2),
      ]);

      expect(await build(remote).hydrate(), EventHydrateOutcome.drained);
      expect(await attending(), ['e-stale', 'e-1']);
    });

    test('reads what it may purge before page 1 is requested', () async {
      // Another tab's pass caches e-new while this pass's page 1 is in
      // flight, from a newer read of the list, so this page 1 could not have
      // named it.
      final remote = FakeEventRemote((_) async {
        await attend(_row('e-new', 70));
        return _page([_row('e-1', 10)]);
      });

      expect(await build(remote).hydrate(), EventHydrateOutcome.complete);
      expect(await attending(), ['e-new', 'e-1']);
    });

    test('leaves an event cached again while page 1 is in flight', () async {
      // Page 1 was read before the user was invited back to e-old, and
      // another tab's pass, reading the list after, cached it again before
      // this page came back.
      await attend(_row('e-old', 30));
      final remote = FakeEventRemote((_) async {
        await attend(_row('e-old', 30));
        return _page([_row('e-1', 10)]);
      });

      expect(await build(remote).hydrate(), EventHydrateOutcome.complete);
      expect(await attending(), ['e-old', 'e-1']);
    });

    test('a read-only event is never purged', () async {
      await repository.cacheEvent(
        _row('e-read', 30),
        source: EventAccessSource.read,
      );
      final remote = FakeEventRemote.pages([
        _page([_row('e-1', 10)]),
      ]);

      expect(await build(remote).hydrate(), EventHydrateOutcome.complete);
      expect(await repository.getEvent('e-read'), isNotNull);
    });

    test('logs the events whose attendance it removed', () async {
      // An event leaving someone's list is the one thing a pass does that a
      // user can see go wrong, so it leaves a record.
      final logger = _MockBgeLogger();
      await attend(_row('e-gone', 30));
      final remote = FakeEventRemote.pages([
        _page([_row('e-1', 10)]),
      ]);

      await build(remote, logger: logger).hydrate();

      final context =
          verify(
                () => logger.info(any(), context: captureAny(named: 'context')),
              ).captured.single
              as Map<String, dynamic>;
      expect(context['eventIds'], ['e-gone']);
    });
  });

  group('failures never escape', () {
    test('a failed page keeps every cached event', () async {
      // A server older than the events routes answers the list with a 404,
      // which the remote reads as transient; offline is the same.
      await attend(_row('e-2', 20));
      await attend(_row('e-1', 10));
      final remote = FakeEventRemote(
        (_) => throw const EventRemoteTransientException('offline'),
      );

      expect(await build(remote).hydrate(), EventHydrateOutcome.failed);
      expect(await attending(), ['e-2', 'e-1']);
    });

    test('a failed later page still caches what came before', () async {
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-4', 40), _row('e-3', 30)],
          limit: 2,
          total: 4,
          hasMore: true,
        ),
      ], failOnPage: 2);

      expect(
        await build(remote, limit: 2).hydrate(),
        EventHydrateOutcome.failed,
      );
      expect(await attending(), ['e-4', 'e-3']);
    });

    test('a failure after page 1\'s purge still fails the pass', () async {
      // Page 1's purge runs before page 2 is requested, so what it removed
      // stays removed when a later page fails.
      await attend(_row('e-stale', 35));
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-4', 40), _row('e-3', 30)],
          limit: 2,
          total: 4,
          hasMore: true,
        ),
      ], failOnPage: 2);

      expect(
        await build(remote, limit: 2).hydrate(),
        EventHydrateOutcome.failed,
      );
      expect(await repository.getEvent('e-stale'), isNull);
    });

    test('a session that can no longer be confirmed stops the pass', () async {
      // On web another tab can move the shared session to another user while
      // a page is in flight, and the page then holds that user's events.
      await attend(_row('e-stale', 55));
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-6', 60), _row('e-5', 50)],
          limit: 2,
          total: 3,
          hasMore: true,
        ),
        _page([_row('e-4', 40)], page: 2, limit: 2, total: 3),
      ]);

      final outcome = await build(
        remote,
        limit: 2,
        confirmSession: () async => false,
      ).hydrate();

      expect(outcome, EventHydrateOutcome.failed);
      expect(await attending(), ['e-stale']);
      expect(remote.requests, [(page: 1, limit: 2)]);
    });

    test('a session that can no longer be confirmed on a later page stops the '
        'pass there', () async {
      final answers = [true, false];
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-6', 60), _row('e-5', 50)],
          limit: 2,
          total: 5,
          hasMore: true,
        ),
        _page(
          [_row('e-4', 40), _row('e-3', 30)],
          page: 2,
          limit: 2,
          total: 5,
          hasMore: true,
        ),
        _page([_row('e-2', 20)], page: 3, limit: 2, total: 5),
      ]);

      final outcome = await build(
        remote,
        limit: 2,
        confirmSession: () async => answers.removeAt(0),
      ).hydrate();

      expect(outcome, EventHydrateOutcome.failed);
      expect(await attending(), ['e-6', 'e-5']);
      expect(remote.requests, [(page: 1, limit: 2), (page: 2, limit: 2)]);
    });

    test('a later page that says it has more past its own last page '
        'fails', () async {
      // Two pages counted, and the second says a third follows. Nothing else
      // would stop the drain short of the server's offset ceiling.
      final remote = FakeEventRemote.pages([
        _page(
          [_row('e-4', 40), _row('e-3', 30)],
          limit: 2,
          total: 4,
          hasMore: true,
        ),
        _page(
          [_row('e-2', 20), _row('e-1', 10)],
          page: 2,
          limit: 2,
          total: 4,
          hasMore: true,
        ),
      ]);

      expect(
        await build(remote, limit: 2).hydrate(),
        EventHydrateOutcome.failed,
      );
      expect(remote.requests, [(page: 1, limit: 2), (page: 2, limit: 2)]);
    });

    test('a session check that throws stops the pass', () async {
      final remote = FakeEventRemote.pages([
        _page([_row('e-1', 10)]),
      ]);

      final outcome = await build(
        remote,
        confirmSession: () async => throw StateError('no session to ask'),
      ).hydrate();

      expect(outcome, EventHydrateOutcome.failed);
      expect(await attending(), isEmpty);
    });

    test('never throws', () async {
      // The session ends while page 1 is in flight. Its scope disposes the
      // repository, so the write that follows throws StateError.
      final remote = FakeEventRemote((_) async {
        await repository.onDispose();
        return _page([_row('e-1', 10)]);
      });

      expect(await build(remote).hydrate(), EventHydrateOutcome.failed);
    });

    test('a cache it cannot read fails the pass before any request', () async {
      // The session ended before the pass began, so reading what it may
      // purge is the first call to find the repository disposed.
      await attend(_row('e-stale', 30));
      await repository.onDispose();
      final remote = FakeEventRemote.pages([_page(const [])]);

      expect(await build(remote).hydrate(), EventHydrateOutcome.failed);
      expect(remote.requests, isEmpty);
      expect(await nextSession().getEvent('e-stale'), isNotNull);
    });

    test('a purge that throws fails the pass', () async {
      // The page's write goes through, so the purge is the first call to
      // fail.
      await attend(_row('e-stale', 30));
      final cache = _PurgeFails(repository);
      final remote = FakeEventRemote.pages([
        _page([_row('e-1', 10)]),
      ]);

      final outcome = await EventHydrator(
        repository: cache,
        remote: remote,
      ).hydrate();

      expect(outcome, EventHydrateOutcome.failed);
      expect(cache.purgeAsked, isTrue);
      expect(await attending(), ['e-stale', 'e-1']);
    });

    test('a request the remote rejects locally fails the pass', () async {
      // ArgumentError, outside the remote's own exception family, for
      // paging it refuses before sending anything.
      await attend(_row('e-stale', 30));
      final remote = FakeEventRemote.pages(
        const [],
        failOnPage: 1,
        error: ArgumentError('page'),
      );

      expect(await build(remote).hydrate(), EventHydrateOutcome.failed);
      expect(await repository.getEvent('e-stale'), isNotNull);
    });
  });
}
