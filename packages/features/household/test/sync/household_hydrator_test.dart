import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'package:household/household.dart';

class MockHouseholdRepository extends Mock implements HouseholdRepository {}

class MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

class MockBgeLogger extends Mock implements BgeLogger {}

// ── Fixtures ───────────────────────────────────────────────────────────────────

Household _household(String id) => Household(
  id: id,
  name: 'Household $id',
  createdAt: DateTime.utc(2024, 1, 15),
  updatedAt: DateTime.utc(2024, 1, 15),
);

HouseholdMember _member(String id, {required String householdId}) =>
    HouseholdMember(
      id: id,
      userId: 'user-$id',
      householdId: householdId,
      role: HouseholdRole.householdMember,
      createdAt: DateTime.utc(2024, 1, 15),
      updatedAt: DateTime.utc(2024, 1, 15),
    );

/// One page of [ids], each household carrying a single member.
PaginatedResult<HouseholdWithMembers> _page({
  required List<String> ids,
  required int page,
  required int limit,
  required int total,
  required bool hasMore,
}) => PaginatedResult(
  items: [
    for (final id in ids)
      (household: _household(id), members: [_member('m-$id', householdId: id)]),
  ],
  meta: PaginationMeta(
    page: page,
    limit: limit,
    total: total,
    totalPages: (total / limit).ceil(),
    hasMore: hasMore,
  ),
);

void main() {
  late MockHouseholdRepository repo;
  late MockHouseholdRemoteDataSource remote;

  setUpAll(() {
    registerFallbackValue(_household('fallback'));
    registerFallbackValue(<HouseholdMember>[]);
    registerFallbackValue(<String>{});
  });

  setUp(() {
    repo = MockHouseholdRepository();
    remote = MockHouseholdRemoteDataSource();

    when(() => repo.cacheHouseholdWithRoster(any(), any()))
        .thenAnswer((_) async => HouseholdRosterWrite.replaced);
    when(() => repo.purgeableHouseholdIds())
        .thenAnswer((_) async => <String>{});
    when(
      () => repo.purgeHouseholdsAbsentFrom(
        any(),
        purgeable: any(named: 'purgeable'),
      ),
    ).thenAnswer((_) async => <String>{});
  });

  /// The households the pass wrote, in order.
  List<String> writtenIds() =>
      verify(() => repo.cacheHouseholdWithRoster(captureAny(), any())).captured
          .cast<Household>()
          .map((h) => h.id)
          .toList();

  HouseholdHydrator build({
    int limit = HouseholdRemoteDataSource.maxPageSize,
  }) => HouseholdHydrator(repository: repo, remote: remote, limit: limit);

  group('HouseholdHydrator — the complete set', () {
    test('caches every household from a single-page complete set', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => _page(
          ids: ['h-1', 'h-2'],
          page: 1,
          limit: 100,
          total: 2,
          hasMore: false,
        ),
      );

      await build().hydrate();

      expect(writtenIds(), equals(['h-1', 'h-2']));
    });

    test(
      'writes each household with the roster embedded in the page',
      () async {
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer(
          (_) async => _page(
            ids: ['h-1'],
            page: 1,
            limit: 100,
            total: 1,
            hasMore: false,
          ),
        );

        await build().hydrate();

        final rosters = verify(
          () => repo.cacheHouseholdWithRoster(any(), captureAny()),
        ).captured.cast<List<HouseholdMember>>();
        expect(rosters.single.single.id, equals('m-h-1'));
        expect(rosters.single.single.householdId, equals('h-1'));
      },
    );

    test('requests page 1 at the server page-size cap', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async =>
            _page(ids: const [], page: 1, limit: 100, total: 0, hasMore: false),
      );

      await build().hydrate();

      verify(() => remote.fetchHouseholds(page: 1, limit: 100)).called(1);
    });
  });

  group('HouseholdHydrator — the drain', () {
    test('follows hasMore across pages and caches all of them', () async {
      when(() => remote.fetchHouseholds(page: 1, limit: 2)).thenAnswer(
        (_) async => _page(
          ids: ['h-1', 'h-2'],
          page: 1,
          limit: 2,
          total: 5,
          hasMore: true,
        ),
      );
      when(() => remote.fetchHouseholds(page: 2, limit: 2)).thenAnswer(
        (_) async => _page(
          ids: ['h-3', 'h-4'],
          page: 2,
          limit: 2,
          total: 5,
          hasMore: true,
        ),
      );
      when(() => remote.fetchHouseholds(page: 3, limit: 2)).thenAnswer(
        (_) async =>
            _page(ids: ['h-5'], page: 3, limit: 2, total: 5, hasMore: false),
      );

      await build(limit: 2).hydrate();

      expect(writtenIds(), equals(['h-1', 'h-2', 'h-3', 'h-4', 'h-5']));
    });

    test('stops on hasMore false even when the page is full', () async {
      // Never infer the end of the list from a short page: a full final
      // page with hasMore false is the end.
      when(() => remote.fetchHouseholds(page: 1, limit: 2)).thenAnswer(
        (_) async => _page(
          ids: ['h-1', 'h-2'],
          page: 1,
          limit: 2,
          total: 2,
          hasMore: false,
        ),
      );

      await build(limit: 2).hydrate();

      verify(() => remote.fetchHouseholds(page: 1, limit: 2)).called(1);
      verifyNever(
        () => remote.fetchHouseholds(page: 2, limit: any(named: 'limit')),
      );
    });
  });

  group('HouseholdHydrator — the purge (#268)', () {
    test('a single-page snapshot purges against the ids it returned', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => _page(
          ids: ['h-1', 'h-2'],
          page: 1,
          limit: 100,
          total: 2,
          hasMore: false,
        ),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.complete));

      verify(
        () => repo.purgeHouseholdsAbsentFrom({
          'h-1',
          'h-2',
        }, purgeable: any(named: 'purgeable')),
      ).called(1);
    });

    test('reads what it may purge before page 1 is requested', () async {
      // A household that becomes purgeable while the request is in flight
      // is one the snapshot may not have seen. Read after the response, the
      // purge could remove a household created during the pass.
      var requested = false;
      when(() => repo.purgeableHouseholdIds())
          .thenAnswer((_) async => requested ? {'h-old', 'h-new'} : {'h-old'});
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async {
        requested = true;
        return _page(
          ids: ['h-1'],
          page: 1,
          limit: 100,
          total: 1,
          hasMore: false,
        );
      });

      await build().hydrate();

      verify(() => repo.purgeHouseholdsAbsentFrom(any(), purgeable: {'h-old'}))
          .called(1);
    });

    test('an empty snapshot is still one, and purges', () async {
      // The user removed from their last household is exactly the case
      // this exists for.
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async =>
            _page(ids: const [], page: 1, limit: 100, total: 0, hasMore: false),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.complete));

      verify(
        () => repo.purgeHouseholdsAbsentFrom(
          const <String>{},
          purgeable: any(named: 'purgeable'),
        ),
      ).called(1);
    });

    test('logs the households it removed', () async {
      // A household leaving someone's list is the one thing this pass does
      // that a user can see go wrong, so it leaves a record.
      final logger = MockBgeLogger();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 100, total: 1, hasMore: false),
      );
      when(
        () => repo.purgeHouseholdsAbsentFrom(
          any(),
          purgeable: any(named: 'purgeable'),
        ),
      ).thenAnswer((_) async => {'h-gone'});

      await HouseholdHydrator(
        repository: repo,
        remote: remote,
        logger: logger,
      ).hydrate();

      final context =
          verify(
                () => logger.info(any(), context: captureAny(named: 'context')),
              ).captured.single
              as Map<String, dynamic>;
      expect(context['householdIds'], equals(['h-gone']));
    });
  });

  group('HouseholdHydrator — a roster it could not trust (#268)', () {
    test('is logged, naming the household', () async {
      // The repository merged it rather than letting it say who left. That
      // is a response missing its roster, which is worth hearing about.
      final logger = MockBgeLogger();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => _page(
          ids: ['h-1', 'h-2'],
          page: 1,
          limit: 100,
          total: 2,
          hasMore: false,
        ),
      );
      when(
        () => repo.cacheHouseholdWithRoster(
          any(that: isA<Household>().having((h) => h.id, 'id', 'h-2')),
          any(),
        ),
      ).thenAnswer((_) async => HouseholdRosterWrite.merged);

      final outcome = await HouseholdHydrator(
        repository: repo,
        remote: remote,
        logger: logger,
      ).hydrate();

      expect(outcome, equals(HydrateOutcome.complete));
      final context =
          verify(
                () => logger.warn(any(), context: captureAny(named: 'context')),
              ).captured.single
              as Map<String, dynamic>;
      expect(context['householdId'], equals('h-2'));
    });
  });

  group('HouseholdHydrator — a drain across pages (#268)', () {
    void stubThreePages() {
      when(() => remote.fetchHouseholds(page: 1, limit: 2)).thenAnswer(
        (_) async => _page(
          ids: ['h-1', 'h-2'],
          page: 1,
          limit: 2,
          total: 5,
          hasMore: true,
        ),
      );
      when(() => remote.fetchHouseholds(page: 2, limit: 2)).thenAnswer(
        (_) async => _page(
          ids: ['h-3', 'h-4'],
          page: 2,
          limit: 2,
          total: 5,
          hasMore: true,
        ),
      );
      when(() => remote.fetchHouseholds(page: 3, limit: 2)).thenAnswer(
        (_) async =>
            _page(ids: ['h-5'], page: 3, limit: 2, total: 5, hasMore: false),
      );
    }

    test('reports drained, not complete', () async {
      // The server's own contract: a walk across pages is not one snapshot,
      // and a live household can slip past a page boundary unseen.
      stubThreePages();

      expect(await build(limit: 2).hydrate(), equals(HydrateOutcome.drained));
    });

    test('purges nothing', () async {
      stubThreePages();

      await build(limit: 2).hydrate();

      verifyNever(
        () => repo.purgeHouseholdsAbsentFrom(
          any(),
          purgeable: any(named: 'purgeable'),
        ),
      );
    });

    test('follows hasMore past the server page-size cap', () async {
      // The list is membership-scoped for a user session (backend#417), so
      // a total above the cap is a user with that many households, not an
      // admin's view of the server. Nothing stops at page 1 any more.
      when(() => remote.fetchHouseholds(page: 1, limit: 100)).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 100, total: 150, hasMore: true),
      );
      when(() => remote.fetchHouseholds(page: 2, limit: 100)).thenAnswer(
        (_) async => _page(
          ids: ['h-2'],
          page: 2,
          limit: 100,
          total: 150,
          hasMore: false,
        ),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.drained));
      expect(writtenIds(), equals(['h-1', 'h-2']));
    });
  });

  group('HouseholdHydrator — a server that contradicts itself', () {
    test('stops at the last page the server counted, rather than trusting '
        'hasMore forever', () async {
      // hasMore true on the last page the server counted is
      // self-contradictory. Left alone the drain walks to the server's
      // page-depth ceiling and is terminated by an ArgumentError ~1000
      // requests later.
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (invocation) async => _page(
          ids: ['h-1', 'h-2'],
          page: invocation.namedArguments[#page] as int,
          limit: 2,
          total: 2,
          hasMore: true,
        ),
      );

      final outcome = await build(limit: 2).hydrate().timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'hydrate() never terminated against a server that always '
          'reports hasMore',
        ),
      );

      verify(() => remote.fetchHouseholds(page: 1, limit: 2)).called(1);
      verifyNever(
        () => remote.fetchHouseholds(page: 2, limit: any(named: 'limit')),
      );
      // Not complete: the envelope cannot be trusted, so nothing may purge
      // against what it produced.
      expect(outcome, equals(HydrateOutcome.failed));
    });

    test('purges nothing when page 1 says it is the last but counts more '
        'than one page', () async {
      // hasMore false licenses the purge only when the envelope agrees with
      // itself. Here it counts 150 households and delivered 100: taking it
      // at its word would remove the 50 it did not send.
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => _page(
          ids: ['h-1'],
          page: 1,
          limit: 100,
          total: 150,
          hasMore: false,
        ),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.failed));

      expect(writtenIds(), equals(['h-1']));
      verifyNever(
        () => repo.purgeHouseholdsAbsentFrom(
          any(),
          purgeable: any(named: 'purgeable'),
        ),
      );
    });
  });

  group('HouseholdHydrator — failures never escape', () {
    test('a transient failure completes instead of throwing', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemoteTransientException('offline', statusCode: 503),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.failed));
    });

    test('a permanent failure completes instead of throwing', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemotePermanentException('bad page', statusCode: 400),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.failed));
    });

    test('a rejected request completes instead of throwing', () async {
      // fetchHouseholds validates paging locally and throws ArgumentError
      // — NOT a HouseholdRemoteException — before spending a round trip.
      // An injected limit outside 1..maxPageSize is the direct route to it.
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(ArgumentError.value(0, 'limit', 'must be between 1 and 100'));

      expect(await build(limit: 0).hydrate(), equals(HydrateOutcome.failed));
    });

    test('keeps the pages already cached when a later page fails', () async {
      when(() => remote.fetchHouseholds(page: 1, limit: 2)).thenAnswer(
        (_) async => _page(
          ids: ['h-1', 'h-2'],
          page: 1,
          limit: 2,
          total: 5,
          hasMore: true,
        ),
      );
      when(() => remote.fetchHouseholds(page: 2, limit: 2)).thenThrow(
        const HouseholdRemoteTransientException('dropped', statusCode: 503),
      );

      expect(await build(limit: 2).hydrate(), equals(HydrateOutcome.failed));

      expect(writtenIds(), equals(['h-1', 'h-2']));
    });

    test('absorbs a scope teardown mid-drain', () async {
      // Scope deactivation disposes the repository; the next write throws
      // StateError from checkNotDisposed(). That must not escape into
      // scope activation, which treats a throw as a wiring failure and
      // signs the user out.
      when(() => remote.fetchHouseholds(page: 1, limit: 2)).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 2, total: 5, hasMore: true),
      );
      when(() => repo.cacheHouseholdWithRoster(any(), any()))
          .thenThrow(StateError('HouseholdRepositoryImpl has been disposed'));

      expect(await build(limit: 2).hydrate(), equals(HydrateOutcome.failed));
    });

    test('a failed purge completes instead of throwing', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 100, total: 1, hasMore: false),
      );
      when(
        () => repo.purgeHouseholdsAbsentFrom(
          any(),
          purgeable: any(named: 'purgeable'),
        ),
      ).thenThrow(StateError('HouseholdRepositoryImpl has been disposed'));

      expect(await build().hydrate(), equals(HydrateOutcome.failed));
    });

    test('a failed read of what it may purge completes instead of throwing, '
        'before requesting anything', () async {
      when(() => repo.purgeableHouseholdIds())
          .thenThrow(StateError('HouseholdRepositoryImpl has been disposed'));

      expect(await build().hydrate(), equals(HydrateOutcome.failed));

      verifyNever(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      );
    });

    test('a pass that failed on a page purges nothing', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemoteTransientException('offline', statusCode: 503),
      );

      await build().hydrate();

      verifyNever(
        () => repo.purgeHouseholdsAbsentFrom(
          any(),
          purgeable: any(named: 'purgeable'),
        ),
      );
    });

    test('stops requesting pages once a write has failed', () async {
      when(() => remote.fetchHouseholds(page: 1, limit: 2)).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 2, total: 5, hasMore: true),
      );
      when(() => repo.cacheHouseholdWithRoster(any(), any()))
          .thenThrow(StateError('HouseholdRepositoryImpl has been disposed'));

      await build(limit: 2).hydrate();

      verifyNever(
        () => remote.fetchHouseholds(page: 2, limit: any(named: 'limit')),
      );
    });
  });

  group('HouseholdHydrator — one pass at a time (#302 D3)', () {
    test('a second call while a pass is in flight joins it rather than '
        'starting a second drain', () async {
      final gate = Completer<PaginatedResult<HouseholdWithMembers>>();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) => gate.future);

      final hydrator = build();
      final first = hydrator.hydrate();
      final second = hydrator.hydrate();

      gate.complete(
        _page(ids: ['h-1'], page: 1, limit: 100, total: 1, hasMore: false),
      );

      expect(await first, equals(HydrateOutcome.complete));
      expect(await second, equals(HydrateOutcome.complete));
      verify(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).called(1);
    });

    test(
      'the joined caller is handed the same outcome, failure included',
      () async {
        final gate = Completer<PaginatedResult<HouseholdWithMembers>>();
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) => gate.future);

        final hydrator = build();
        final first = hydrator.hydrate();
        final second = hydrator.hydrate();

        gate.completeError(StateError('server unreachable'));

        expect(await first, equals(HydrateOutcome.failed));
        expect(await second, equals(HydrateOutcome.failed));
      },
    );

    test(
      'a call after the previous pass settled starts a fresh drain',
      () async {
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer(
          (_) async => _page(
            ids: ['h-1'],
            page: 1,
            limit: 100,
            total: 1,
            hasMore: false,
          ),
        );

        final hydrator = build();
        await hydrator.hydrate();
        await hydrator.hydrate();

        // Single-flight is a concurrency guard, not a cache: the whole point
        // of #302 is that a later trigger asks the server again.
        verify(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).called(2);
      },
    );

    test(
      'a pass that failed does not pin the failure for later callers',
      () async {
        var call = 0;
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async {
          call++;
          if (call == 1) throw StateError('server unreachable');
          return _page(
            ids: ['h-1'],
            page: 1,
            limit: 100,
            total: 1,
            hasMore: false,
          );
        });

        final hydrator = build();

        expect(await hydrator.hydrate(), equals(HydrateOutcome.failed));
        expect(await hydrator.hydrate(), equals(HydrateOutcome.complete));
      },
    );
  });
}
