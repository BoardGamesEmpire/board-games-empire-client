import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';

import 'package:household/household.dart';

class MockHouseholdRepository extends Mock implements HouseholdRepository {}

class MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

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
  });

  setUp(() {
    repo = MockHouseholdRepository();
    remote = MockHouseholdRemoteDataSource();

    when(() => repo.cacheHousehold(any())).thenAnswer((_) async {});
    when(() => repo.cacheMembers(any())).thenAnswer((_) async {});
  });

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

      final cached = verify(
        () => repo.cacheHousehold(captureAny()),
      ).captured.cast<Household>();
      expect(cached.map((h) => h.id), equals(['h-1', 'h-2']));
    });

    test('caches the members embedded in the page', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 100, total: 1, hasMore: false),
      );

      await build().hydrate();

      final cached = verify(
        () => repo.cacheMembers(captureAny()),
      ).captured.cast<List<HouseholdMember>>();
      expect(cached.single.single.id, equals('m-h-1'));
      expect(cached.single.single.householdId, equals('h-1'));
    });

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
      // The drain is only reachable below the server's page-size cap: at
      // limit == maxPageSize, hasMore true implies total > limit, which is
      // the admin degrade. See the class doc.
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

      final cached = verify(
        () => repo.cacheHousehold(captureAny()),
      ).captured.cast<Household>();
      expect(
        cached.map((h) => h.id),
        equals(['h-1', 'h-2', 'h-3', 'h-4', 'h-5']),
      );
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

  group('HouseholdHydrator — the admin-scope degrade', () {
    test('stops after page 1 when total exceeds the page size', () async {
      when(() => remote.fetchHouseholds(page: 1, limit: 100)).thenAnswer(
        (_) async => _page(
          ids: ['h-1'],
          page: 1,
          limit: 100,
          total: 4000,
          hasMore: true,
        ),
      );

      await build().hydrate();

      verify(() => remote.fetchHouseholds(page: 1, limit: 100)).called(1);
      verifyNever(
        () => remote.fetchHouseholds(page: 2, limit: any(named: 'limit')),
      );
    });

    test('still caches the page it did fetch', () async {
      when(() => remote.fetchHouseholds(page: 1, limit: 100)).thenAnswer(
        (_) async => _page(
          ids: ['h-1'],
          page: 1,
          limit: 100,
          total: 4000,
          hasMore: true,
        ),
      );

      await build().hydrate();

      verify(() => repo.cacheHousehold(any())).called(1);
    });

    test('reports the set as incomplete, so no purge may follow', () async {
      when(() => remote.fetchHouseholds(page: 1, limit: 100)).thenAnswer(
        (_) async => _page(
          ids: ['h-1'],
          page: 1,
          limit: 100,
          total: 4000,
          hasMore: true,
        ),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.adminScoped));
    });

    test('reports a drained set as complete', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 100, total: 1, hasMore: false),
      );

      expect(await build().hydrate(), equals(HydrateOutcome.complete));
    });

    test('does not degrade a member-scoped drain below the page cap', () async {
      // total (5) > limit (2) here, but that is ordinary paging, not an
      // admin response. The scope determination is made once, against the
      // server's real page-size cap.
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

      expect(await build(limit: 2).hydrate(), equals(HydrateOutcome.complete));
    });
  });

  group('HouseholdHydrator — a server that contradicts itself', () {
    test('stops at the last page the server counted, rather than trusting '
        'hasMore forever', () async {
      // hasMore true with total <= the page cap is self-contradictory: it
      // is below the admin-degrade threshold, so nothing else stops the
      // drain. Left alone it walks to the server's page-depth ceiling and
      // is terminated by an ArgumentError ~1000 requests later.
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

      final cached = verify(
        () => repo.cacheHousehold(captureAny()),
      ).captured.cast<Household>();
      expect(cached.map((h) => h.id), equals(['h-1', 'h-2']));
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
      when(
        () => repo.cacheHousehold(any()),
      ).thenThrow(StateError('HouseholdRepositoryImpl has been disposed'));

      expect(await build(limit: 2).hydrate(), equals(HydrateOutcome.failed));
    });

    test('stops requesting pages once a write has failed', () async {
      when(() => remote.fetchHouseholds(page: 1, limit: 2)).thenAnswer(
        (_) async =>
            _page(ids: ['h-1'], page: 1, limit: 2, total: 5, hasMore: true),
      );
      when(
        () => repo.cacheHousehold(any()),
      ).thenThrow(StateError('HouseholdRepositoryImpl has been disposed'));

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
