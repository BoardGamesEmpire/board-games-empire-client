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

class _MockEventRepository extends Mock implements EventRepository {}

class _MockBgeLogger extends Mock implements BgeLogger {}

const _kHousehold = 'h-1';
const _kUserId = 'user-abc';

/// What the repository says the pass may purge, before page 1 is requested.
const _purgeable = {'e-stale': 3, 'e-1': 1};

const _gone = EventRemoteNotFoundException('household not found');

/// The household's event [id] as its list returns it. No roster, since the
/// list carries none.
EventSnapshot _row(String id) {
  final createdAt = DateTime.utc(2026, 10, 1, 12);
  return EventSnapshot(
    event: Event(
      id: id,
      title: 'Event $id',
      createdById: 'user-host',
      householdId: _kHousehold,
      type: EventType.casualGathering,
      reach: Reach.private,
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

/// A remote that serves [pages] as the household's list and answers no other
/// read.
FakeEventRemote _remote(List<PaginatedResult<EventSnapshot>> pages) =>
    FakeEventRemote(
      (_) => throw UnimplementedError('a household pass reads no other list'),
    )..householdPages[_kHousehold] = pages;

/// A session check that always says yes, and makes every household read
/// after the page it is first asked about throw [error], as a household
/// deleted, or a network lost, while that page was in flight would.
Future<bool> Function() _thenFails(FakeEventRemote remote, Object error) =>
    () async {
      remote.householdError = error;
      return true;
    };

void main() {
  setUpAll(() {
    registerFallbackValue(EventAccessSource.household);
    registerFallbackValue(<EventSnapshot>[]);
    registerFallbackValue(<String>{});
    registerFallbackValue(<String, int>{});
  });

  group('over a mocked cache', () {
    late _MockEventRepository repository;

    setUp(() {
      repository = _MockEventRepository();
      when(() => repository.purgeableHouseholdEvents(any()))
          .thenAnswer((_) async => _purgeable);
      when(() => repository.cacheEvents(any(), source: any(named: 'source')))
          .thenAnswer((_) async {});
      when(
        () => repository.purgeHouseholdEventsAbsentFrom(
          any(),
          any(),
          purgeable: any(named: 'purgeable'),
        ),
      ).thenAnswer((_) async => const <String>{});
    });

    HouseholdEventsHydrator build(
      FakeEventRemote remote, {
      int limit = EventRemoteDataSource.maxPageSize,
      Future<bool> Function()? confirmSession,
      BgeLogger? logger,
    }) => HouseholdEventsHydrator(
      repository: repository,
      remote: remote,
      limit: limit,
      confirmSession: confirmSession,
      logger: logger,
    );

    void verifyNoPurge() => verifyNever(
      () => repository.purgeHouseholdEventsAbsentFrom(
        any(),
        any(),
        purgeable: any(named: 'purgeable'),
      ),
    );

    void verifyNoWrite() => verifyNever(
      () => repository.cacheEvents(any(), source: any(named: 'source')),
    );

    group('what a pass writes (#503)', () {
      test('caches every page under the household source', () async {
        final first = _page(
          [_row('e-2'), _row('e-1')],
          limit: 2,
          total: 3,
          hasMore: true,
        );
        final second = _page([_row('e-3')], page: 2, limit: 2, total: 3);
        final remote = _remote([first, second]);

        final outcome = await build(remote, limit: 2).hydrate(_kHousehold);

        expect(outcome, HouseholdEventsOutcome.drained);
        verifyInOrder([
          () => repository.cacheEvents(
            first.items,
            source: EventAccessSource.household,
          ),
          () => repository.cacheEvents(
            second.items,
            source: EventAccessSource.household,
          ),
        ]);
        // A list past page 1 is no snapshot of the household's events, so
        // nothing is purged against it.
        verifyNoPurge();
        expect(remote.householdRequests, [
          (householdId: _kHousehold, page: 1, limit: 2),
          (householdId: _kHousehold, page: 2, limit: 2),
        ]);
      });
    });

    group('what a pass removes (#503)', () {
      test('a whole page 1 purges against it', () async {
        final remote = _remote([
          _page([_row('e-2'), _row('e-1')]),
        ]);
        int? requestsWhenRead;
        when(() => repository.purgeableHouseholdEvents(_kHousehold))
            .thenAnswer((_) async {
              requestsWhenRead = remote.householdRequests.length;
              return _purgeable;
            });

        // Its defaults: the server's page-size cap, and no session to check,
        // as on native.
        final outcome = await HouseholdEventsHydrator(
          repository: repository,
          remote: remote,
        ).hydrate(_kHousehold);

        expect(outcome, HouseholdEventsOutcome.complete);
        expect(
          requestsWhenRead,
          0,
          reason: 'the purgeable set is read before page 1 is requested',
        );
        verify(
          () => repository.purgeHouseholdEventsAbsentFrom(_kHousehold, {
            'e-2',
            'e-1',
          }, purgeable: _purgeable),
        ).called(1);
        expect(remote.householdRequests, [
          (householdId: _kHousehold, page: 1, limit: 100),
        ]);
      });

      test(
        'an emptied list is whole, and purges every purgeable row',
        () async {
          // The household's last upcoming event was cancelled. An empty page
          // counts no pages, and it is still the whole list.
          final remote = _remote([_page(const [])]);

          expect(
            await build(remote).hydrate(_kHousehold),
            HouseholdEventsOutcome.complete,
          );
          verify(
            () => repository.purgeHouseholdEventsAbsentFrom(
              _kHousehold,
              <String>{},
              purgeable: _purgeable,
            ),
          ).called(1);
        },
      );

      group('a page 1 that contradicts itself purges nothing and fails', () {
        // A page that says it is the last licenses removing whatever it
        // leaves out, so the rest of its envelope must agree that it is the
        // whole list.
        final envelopes = {
          'counts more than one page': _page([_row('e-1')], totalPages: 2),
          'is numbered as another page': _page([_row('e-1')], page: 2),
          'sends more events than it counts': _page([
            _row('e-1'),
            _row('e-0'),
          ], total: 1),
          'counts more events than a page holds': _page(
            [_row('e-1'), _row('e-0')],
            limit: 1,
            total: 2,
            totalPages: 1,
          ),
        };
        for (final MapEntry(key: contradiction, value: envelope)
            in envelopes.entries) {
          test('when it $contradiction', () async {
            final remote = _remote([envelope]);

            expect(
              await build(remote).hydrate(_kHousehold),
              HouseholdEventsOutcome.failed,
            );
            // Its rows were written before it was judged, as the user's own
            // list writes them.
            verify(
              () => repository.cacheEvents(
                envelope.items,
                source: EventAccessSource.household,
              ),
            ).called(1);
            verifyNoPurge();
          });
        }
      });

      test('a short page 1 caches and purges nothing', () async {
        // Counted in the same read as the rows, so an event it counts and
        // did not send may still be the household's.
        final short = _page([_row('e-1')], total: 2);
        final remote = _remote([short]);

        expect(
          await build(remote).hydrate(_kHousehold),
          HouseholdEventsOutcome.drained,
        );
        verify(
          () => repository.cacheEvents(
            short.items,
            source: EventAccessSource.household,
          ),
        ).called(1);
        verifyNoPurge();
      });

      test('a full page 1 with more to follow purges nothing', () async {
        // The list is ordered by date, which can move, so an event missing
        // from page 1's range may only have moved past it. No window is
        // purged.
        final remote = _remote([
          _page([_row('e-2'), _row('e-1')], limit: 2, total: 3, hasMore: true),
          _page([_row('e-0')], page: 2, limit: 2, total: 3),
        ]);

        expect(
          await build(remote, limit: 2).hydrate(_kHousehold),
          HouseholdEventsOutcome.drained,
        );
        verifyNoPurge();
      });

      test('hasMore past its own last page fails', () async {
        // It counts one page and says another follows. Nothing else would
        // stop the drain short of the server's offset ceiling.
        final remote = _remote([
          _page([_row('e-2'), _row('e-1')], limit: 2, total: 2, hasMore: true),
        ]);

        expect(
          await build(remote, limit: 2).hydrate(_kHousehold),
          HouseholdEventsOutcome.failed,
        );
        expect(remote.householdRequests, [
          (householdId: _kHousehold, page: 1, limit: 2),
        ]);
        verifyNoPurge();
      });

      test('a 404 purges every purgeable row and reports notFound', () async {
        // The household is missing or deleted, so it lists nothing.
        final remote = _remote(const [])..householdError = _gone;

        expect(
          await build(remote).hydrate(_kHousehold),
          HouseholdEventsOutcome.notFound,
        );
        verify(
          () => repository.purgeHouseholdEventsAbsentFrom(
            _kHousehold,
            <String>{},
            purgeable: _purgeable,
          ),
        ).called(1);
        verifyNoWrite();
      });

      test('a 404 on a later page purges against the set read before page 1, '
          'and reports notFound', () async {
        // Deleted while page 1 was in flight. The repository keeps what page
        // 1 wrote, since it was written after that set was read.
        final first = _page(
          [_row('e-2'), _row('e-1')],
          limit: 2,
          total: 3,
          hasMore: true,
        );
        final remote = _remote([first]);
        var asked = 0;
        final thenGone = _thenFails(remote, _gone);

        final outcome = await build(
          remote,
          limit: 2,
          confirmSession: () {
            asked++;
            return thenGone();
          },
        ).hydrate(_kHousehold);

        expect(outcome, HouseholdEventsOutcome.notFound);
        verifyInOrder([
          () => repository.purgeableHouseholdEvents(_kHousehold),
          () => repository.cacheEvents(
            first.items,
            source: EventAccessSource.household,
          ),
          () => repository.purgeHouseholdEventsAbsentFrom(
            _kHousehold,
            <String>{},
            purgeable: _purgeable,
          ),
        ]);
        expect(remote.householdRequests, hasLength(2));
        expect(
          asked,
          2,
          reason: 'once before page 1 is written, once before the purge',
        );
      });

      test('a 404 on a session that can no longer be confirmed purges nothing '
          'and fails', () async {
        // The 404 was read as whoever holds the session now, and the purge is
        // a write like any page's.
        final remote = _remote(const [])..householdError = _gone;
        var asked = 0;

        final outcome = await build(
          remote,
          confirmSession: () async {
            asked++;
            return false;
          },
        ).hydrate(_kHousehold);

        expect(outcome, HouseholdEventsOutcome.failed);
        expect(asked, 1);
        verifyNoPurge();
      });

      test('a 403 fails and purges nothing', () async {
        // The household exists, but this user may not read its events. Only a
        // missing household lists nothing.
        final remote = _remote(const [])
          ..householdError = const EventRemoteForbiddenException('forbidden');

        expect(
          await build(remote).hydrate(_kHousehold),
          HouseholdEventsOutcome.failed,
        );
        verifyNoPurge();
      });

      test('logs the events it removed', () async {
        // An event leaving a household's section is the one thing a pass
        // does that a user can see go wrong, so it leaves a record.
        final logger = _MockBgeLogger();
        when(
          () => repository.purgeHouseholdEventsAbsentFrom(
            any(),
            any(),
            purgeable: any(named: 'purgeable'),
          ),
        ).thenAnswer((_) async => {'e-stale'});
        final remote = _remote([
          _page([_row('e-1')]),
        ]);

        await build(remote, logger: logger).hydrate(_kHousehold);

        final context =
            verify(
                  () =>
                      logger.info(any(), context: captureAny(named: 'context')),
                ).captured.single
                as Map<String, dynamic>;
        expect(context['householdId'], _kHousehold);
        expect(context['eventIds'], ['e-stale']);
      });
    });

    group('failures never escape', () {
      test('a failed page fails the pass and keeps what was written', () async {
        final first = _page(
          [_row('e-2'), _row('e-1')],
          limit: 2,
          total: 3,
          hasMore: true,
        );
        final remote = _remote([first]);

        final outcome = await build(
          remote,
          limit: 2,
          confirmSession: _thenFails(
            remote,
            const EventRemoteTransientException('offline'),
          ),
        ).hydrate(_kHousehold);

        expect(outcome, HouseholdEventsOutcome.failed);
        verify(
          () => repository.cacheEvents(
            first.items,
            source: EventAccessSource.household,
          ),
        ).called(1);
        verifyNoPurge();
        expect(remote.householdRequests, hasLength(2));
      });

      test('an unconfirmed session stops before writing that page', () async {
        // On web another tab can move the shared session to another user
        // while a page is in flight, and the page then holds what the
        // household shows that user.
        final remote = _remote([
          _page([_row('e-1')]),
        ]);

        final outcome = await build(
          remote,
          confirmSession: () async => false,
        ).hydrate(_kHousehold);

        expect(outcome, HouseholdEventsOutcome.failed);
        verifyNoWrite();
        verifyNoPurge();
      });

      test('a session check that throws stops the pass', () async {
        final remote = _remote([
          _page([_row('e-1')]),
        ]);

        final outcome = await build(
          remote,
          confirmSession: () async => throw StateError('no session to ask'),
        ).hydrate(_kHousehold);

        expect(outcome, HouseholdEventsOutcome.failed);
        verifyNoWrite();
      });

      test('a request the remote rejects locally fails the pass', () async {
        // ArgumentError, outside the remote's own exception family, for an
        // id or paging it refuses before sending anything.
        final remote = _remote(const [])
          ..householdError = ArgumentError('householdId');

        expect(
          await build(remote).hydrate(_kHousehold),
          HouseholdEventsOutcome.failed,
        );
        verifyNoPurge();
      });

      group('a repository that throws fails, never throws', () {
        // The session ended mid-pass, and its scope disposed the repository.
        final disposed = StateError('the repository is disposed');

        test('reading what it may purge, before any request', () async {
          when(() => repository.purgeableHouseholdEvents(any()))
              .thenThrow(disposed);
          final remote = _remote([_page(const [])]);

          expect(
            await build(remote).hydrate(_kHousehold),
            HouseholdEventsOutcome.failed,
          );
          expect(remote.householdRequests, isEmpty);
        });

        test('writing a page', () async {
          when(
            () => repository.cacheEvents(any(), source: any(named: 'source')),
          ).thenThrow(disposed);
          final remote = _remote([
            _page([_row('e-1')]),
          ]);

          expect(
            await build(remote).hydrate(_kHousehold),
            HouseholdEventsOutcome.failed,
          );
          verifyNoPurge();
        });

        test('purging against a whole page 1', () async {
          when(
            () => repository.purgeHouseholdEventsAbsentFrom(
              any(),
              any(),
              purgeable: any(named: 'purgeable'),
            ),
          ).thenThrow(disposed);
          final remote = _remote([
            _page([_row('e-1')]),
          ]);

          expect(
            await build(remote).hydrate(_kHousehold),
            HouseholdEventsOutcome.failed,
          );
        });

        test('purging after a 404', () async {
          when(
            () => repository.purgeHouseholdEventsAbsentFrom(
              any(),
              any(),
              purgeable: any(named: 'purgeable'),
            ),
          ).thenThrow(disposed);
          final remote = _remote(const [])..householdError = _gone;

          expect(
            await build(remote).hydrate(_kHousehold),
            HouseholdEventsOutcome.failed,
          );
        });
      });
    });
  });

  // What the mocked tests leave to the repository, over the real one: the
  // purge removes only what the pass may, and keeps what it wrote.
  group('over the real cache (#503)', () {
    late ServerDatabase db;
    late EventRepositoryImpl repository;

    setUp(() {
      db = inMemoryServerDatabase();
      repository = EventRepositoryImpl(
        db,
        userId: _kUserId,
        syncQueue: SyncQueueRepositoryImpl(
          db,
          const LocalClockService(),
          userId: _kUserId,
        ),
        clock: const LocalClockService(),
      );
    });

    tearDown(() async => db.close());

    /// Caches [id] as the household's list sent it, as an earlier pass would
    /// have.
    Future<void> listedBefore(String id) =>
        repository.cacheEvent(_row(id), source: EventAccessSource.household);

    /// The ids of the household's events, as its section reads them.
    Future<Set<String>> section() async => {
      for (final item
          in await repository.watchHouseholdEventListItems(_kHousehold).first)
        item.event.id,
    };

    test('an event the household stopped listing leaves its section, and the '
        'cache with its last access', () async {
      await listedBefore('e-cancelled');
      await listedBefore('e-attended');
      await repository.cacheEvent(
        _row('e-attended'),
        source: EventAccessSource.attending,
      );
      final remote = _remote([
        _page([_row('e-1')]),
      ]);

      final outcome = await HouseholdEventsHydrator(
        repository: repository,
        remote: remote,
      ).hydrate(_kHousehold);

      expect(outcome, HouseholdEventsOutcome.complete);
      expect(await section(), {'e-1'});
      expect(await repository.getEvent('e-cancelled'), isNull);
      expect(
        await repository.getEvent('e-attended'),
        isNotNull,
        reason:
            'the user still attends it, which the household list does '
            'not speak for',
      );
    });

    test('a 404 on a later page keeps what the pass wrote', () async {
      await listedBefore('e-stale');
      await listedBefore('e-1');
      final remote = _remote([
        _page([_row('e-2'), _row('e-1')], limit: 2, total: 3, hasMore: true),
      ]);

      final outcome = await HouseholdEventsHydrator(
        repository: repository,
        remote: remote,
        limit: 2,
        confirmSession: _thenFails(remote, _gone),
      ).hydrate(_kHousehold);

      expect(outcome, HouseholdEventsOutcome.notFound);
      expect(await section(), {'e-2', 'e-1'});
      expect(await repository.getEvent('e-stale'), isNull);
    });
  });
}
